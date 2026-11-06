package codex

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// The source native account owns refresh tokens and its file/keychain policy.
// Isolated processes only hold access credentials in native ephemeral storage.
type isolatedAuthentication struct {
	sync.Mutex
	credentials nativeAccessCredentials
}

type nativeAccessCredentials struct {
	method, token, account, user, plan string
}

func (c nativeAccessCredentials) chatgptTokens() Map {
	return Map{"accessToken": c.token, "chatgptAccountId": c.account, "chatgptPlanType": c.plan}
}

type sourceAuthGate struct {
	slot  chan struct{}
	users int
}

var sourceAuthGates = struct {
	sync.Mutex
	entries map[string]*sourceAuthGate
}{entries: make(map[string]*sourceAuthGate)}

// Serializing the entire native read/refresh avoids rotating the same grant in
// several isolated servers in this runtime at once. Native Codex still
// reconciles other clients.
// Entries only live while callers hold or wait for the gate; no tokens are cached.
func acquireSourceAuth(ctx context.Context, source LaunchOptions) (func(), error) {
	home, err := filepath.Abs(ceCodexHome(ceEnvironment(source.Environment)))
	if err != nil {
		return nil, err
	}
	if canonical, err := filepath.EvalSymlinks(home); err == nil {
		home = canonical
	}
	sourceAuthGates.Lock()
	gate := sourceAuthGates.entries[home]
	if gate == nil {
		gate = &sourceAuthGate{slot: make(chan struct{}, 1)}
		sourceAuthGates.entries[home] = gate
	}
	gate.users++
	sourceAuthGates.Unlock()
	releaseReference := func() {
		sourceAuthGates.Lock()
		gate.users--
		if gate.users == 0 {
			delete(sourceAuthGates.entries, home)
		}
		sourceAuthGates.Unlock()
	}
	select {
	case gate.slot <- struct{}{}:
		return func() { <-gate.slot; releaseReference() }, nil
	case <-ctx.Done():
		releaseReference()
		return nil, ctx.Err()
	}
}

func readNativeAccessCredentials(ctx context.Context, source LaunchOptions, previous nativeAccessCredentials) (credentials nativeAccessCredentials, err error) {
	release, err := acquireSourceAuth(ctx, source)
	if err != nil {
		return credentials, err
	}
	defer release()
	// A fresh native process reloads external login/rotation before every read.
	// A retained source AuthManager can otherwise keep an obsolete cached grant.
	server, err := StartAppServer(ctx, source)
	if err != nil {
		return credentials, err
	}
	defer func() { err = errors.Join(err, server.Close()) }()
	read := func(refresh bool) (nativeAccessCredentials, error) {
		result, err := server.Call(ctx, "getAuthStatus", Map{"includeToken": true, "refreshToken": refresh})
		if err != nil {
			return nativeAccessCredentials{}, fmt.Errorf("read native Codex authentication: %w", err)
		}
		return decodeNativeAccessCredentials(result)
	}
	credentials, err = read(false)
	if err != nil || previous.token == "" {
		return credentials, err
	}
	if credentials.method != "chatgpt" || credentials.account != previous.account || credentials.user != previous.user {
		return nativeAccessCredentials{}, errors.New("Codex 原生登录账号已变化，请重新打开会话")
	}
	if credentials.token == previous.token {
		credentials, err = read(true)
		if err != nil {
			return nativeAccessCredentials{}, err
		}
		if credentials.method != "chatgpt" || credentials.account != previous.account || credentials.user != previous.user {
			return nativeAccessCredentials{}, errors.New("Codex 原生登录账号已变化，请重新打开会话")
		}
		// getAuthStatus can return the old token after a transient refresh error.
		// Returning it as a success would make the isolated server retry a 401.
		if credentials.token == previous.token {
			return nativeAccessCredentials{}, errors.New("Codex 原生登录未能刷新访问凭据，请检查原生登录后重试")
		}
	}
	return credentials, nil
}

func decodeNativeAccessCredentials(result Map) (nativeAccessCredentials, error) {
	c := nativeAccessCredentials{method: str(result["authMethod"]), token: str(result["authToken"])}
	if required, ok := result["requiresOpenaiAuth"].(bool); ok && !required {
		return nativeAccessCredentials{}, nil
	}
	if c.token == "" {
		return nativeAccessCredentials{}, errors.New("Codex 原生登录不可用，请在 Codex 中重新登录")
	}
	switch c.method {
	case "apikey":
		return c, nil
	case "chatgpt":
		// Native Codex supplied this token; these claims select the same account,
		// not a new authority or a substitute for provider token verification.
		parts := strings.Split(c.token, ".")
		if len(parts) != 3 {
			break
		}
		data, err := base64.RawURLEncoding.DecodeString(parts[1])
		if err != nil {
			break
		}
		var claims struct {
			Auth struct {
				Account string `json:"chatgpt_account_id"`
				Plan    string `json:"chatgpt_plan_type"`
				User    string `json:"chatgpt_user_id"`
				UserID  string `json:"user_id"`
			} `json:"https://api.openai.com/auth"`
		}
		if json.Unmarshal(data, &claims) != nil || strings.TrimSpace(claims.Auth.Account) == "" {
			break
		}
		user := claims.Auth.User
		if user == "" {
			user = claims.Auth.UserID
		}
		if strings.TrimSpace(user) == "" {
			break
		}
		c.account, c.user, c.plan = claims.Auth.Account, user, claims.Auth.Plan
		return c, nil
	}
	return nativeAccessCredentials{}, errors.New("Codex 原生登录返回了不支持或无效的访问凭据")
}

func (s *AppServer) initializeIsolatedAuthentication(ctx context.Context) error {
	credentials, err := readNativeAccessCredentials(ctx, *s.launch.AuthSource, nativeAccessCredentials{})
	if err != nil {
		return err
	}
	if credentials.token == "" {
		return nil // The configured provider owns authentication through its config/environment.
	}
	params := credentials.chatgptTokens()
	params["type"] = "chatgptAuthTokens"
	if credentials.method == "apikey" {
		params = Map{"type": "apiKey", "apiKey": credentials.token}
	}
	s.auth.Lock()
	s.auth.credentials = credentials
	s.auth.Unlock()
	result, err := s.Call(ctx, "account/login/start", params)
	if err != nil {
		return fmt.Errorf("initialize isolated Codex authentication: %w", err)
	}
	if result["type"] != params["type"] {
		return errors.New("Codex did not confirm the isolated authentication mode")
	}
	return nil
}

func (s *AppServer) refreshIsolatedAuthentication(id any, params Map) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.authWorkers.Add(1)
	s.mu.Unlock()
	// Do not block native notifications or transport response routing on a source
	// refresh. Closing the owner cancels and joins every admitted auth request.
	go func() {
		defer s.authWorkers.Done()
		ctx, cancel := context.WithTimeout(s.authContext, 9*time.Second)
		defer cancel()
		s.auth.Lock()
		previous := s.auth.credentials
		s.auth.Unlock()
		var credentials nativeAccessCredentials
		var err error
		if previous.method != "chatgpt" || str(params["previousAccountId"]) != previous.account {
			err = errors.New("Codex authentication refresh account does not match this session")
		} else {
			credentials, err = readNativeAccessCredentials(ctx, *s.launch.AuthSource, previous)
		}
		result := Map{}
		if err == nil {
			s.auth.Lock()
			s.auth.credentials = credentials
			s.auth.Unlock()
			result = credentials.chatgptTokens()
		}
		_ = s.Reply(id, result, err)
	}()
}

// Package opencode implements the pinned OpenCode 2 HTTP/SSE protocol without a
// JavaScript client runtime. Native plugin callbacks remain in embedded assets.
package opencode

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/processgroup"
)

type Object = map[string]any

type Options struct {
	CWD, ConfigurationCWD, ExecutablePath string
	Environment                           map[string]string
	Config                                Object
	IsolateConfig                         bool
}
type Event struct {
	ID      string `json:"id"`
	Type    string `json:"type"`
	Data    Object `json:"data"`
	Created int64  `json:"created"`
	Durable *struct {
		AggregateID string `json:"aggregateID"`
		Seq         int64  `json:"seq"`
	} `json:"durable,omitempty"`
}
type RawResponse json.RawMessage

var ErrProcessExited = errors.New("OpenCode process exited unexpectedly")

type RequestError struct {
	Status       int
	Method, Path string
}

func (e *RequestError) Error() string {
	return fmt.Sprintf("OpenCode %s %s failed (%d)", e.Method, e.Path, e.Status)
}

type listener struct {
	event func(Event) error
	gap   func(error)
}
type Runtime struct {
	URL, ExecutablePath, Version string
	options                      Options
	password                     string
	client                       *http.Client
	command                      *exec.Cmd
	stdin                        io.WriteCloser
	processDone                  chan struct{}
	processErr                   error
	ctx                          context.Context
	cancel                       context.CancelFunc
	bridge                       *Bridge
	cleanup                      func() error
	mu                           sync.Mutex
	connected                    bool
	ready                        chan struct{}
	listeners                    map[uint64]listener
	nextListener                 uint64
	streamStarted                bool
	streamDone                   chan struct{}
	closeOnce                    sync.Once
	closeErr                     error
}

func environment(values map[string]string) map[string]string {
	if values != nil {
		out := map[string]string{}
		for k, v := range values {
			out[k] = v
		}
		return out
	}
	out := map[string]string{}
	for _, s := range os.Environ() {
		k, v, ok := strings.Cut(s, "=")
		if ok {
			out[k] = v
		}
	}
	return out
}
func randomToken() string {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b[:])
}
func ResolveExecutable(path string, env map[string]string) (string, error) {
	if path != "" {
		info, err := os.Stat(path)
		if err != nil || info.IsDir() || info.Mode()&0111 == 0 {
			return "", errors.New("OpenCode executable is unavailable")
		}
		return filepath.Abs(path)
	}
	for _, dir := range filepath.SplitList(env["PATH"]) {
		p := filepath.Join(dir, "opencode")
		if info, err := os.Stat(p); err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
			return p, nil
		}
	}
	home := env["HOME"]
	if home != "" {
		p := filepath.Join(home, ".opencode", "bin", "opencode")
		if info, err := os.Stat(p); err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
			return p, nil
		}
	}
	return "", errors.New("OpenCode 2 is unavailable; install @opencode/cli")
}

var versionPattern = regexp.MustCompile(`^(?:opencode\s+)?v?(\d+)\.(\d+)\.(\d+)(?:\+[\w.-]+)?$`)

func ReadVersion(ctx context.Context, path, cwd string, env map[string]string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	env = environment(env)
	env["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
	values := make([]string, 0, len(env))
	for k, v := range env {
		values = append(values, k+"="+v)
	}
	// CLI wrappers may leave descendants holding stdout after their leader exits.
	// Join the owned process group before returning or accepting a version.
	out, err := processgroup.Run(ctx, path, []string{"--version"}, cwd, values, 1024)
	if err != nil {
		return "", fmt.Errorf("OpenCode version probe failed: %w", err)
	}
	if out.ExitCode != 0 {
		return "", fmt.Errorf("OpenCode version probe exited with code %d", out.ExitCode)
	}
	m := versionPattern.FindStringSubmatch(strings.TrimSpace(out.Stdout))
	if m == nil {
		return "", errors.New("OpenCode requires stable 2.x version 2.0.25 or newer")
	}
	major, _ := strconv.Atoi(m[1])
	minor, _ := strconv.Atoi(m[2])
	patch, _ := strconv.Atoi(m[3])
	if major != 2 || (minor == 0 && patch < 25) {
		return "", errors.New("OpenCode requires stable 2.x version 2.0.25 or newer")
	}
	return strings.Join(m[1:4], "."), nil
}

// NewRuntime starts one server using OpenCode's native storage and authentication.
func NewRuntime(ctx context.Context, opts Options) (*Runtime, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	opts.Environment = environment(opts.Environment)
	if opts.CWD == "" {
		return nil, errors.New("OpenCode working directory is required")
	}
	startup, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	executable, err := ResolveExecutable(opts.ExecutablePath, opts.Environment)
	if err != nil {
		return nil, err
	}
	version, err := ReadVersion(startup, executable, opts.CWD, opts.Environment)
	if err != nil {
		return nil, err
	}
	bridge, err := NewBridge(opts.IsolateConfig)
	if err != nil {
		return nil, err
	}
	env, cleanup, err := PrepareEnvironment(opts, bridge.Directory)
	if err != nil {
		_ = bridge.Close(false)
		return nil, err
	}
	life, stop := context.WithCancel(ctx)
	r := &Runtime{ExecutablePath: executable, Version: version, options: opts, password: randomToken(), ctx: life, cancel: stop, bridge: bridge, cleanup: cleanup, processDone: make(chan struct{}), ready: make(chan struct{}), listeners: map[uint64]listener{}, streamDone: make(chan struct{})}
	transport := &http.Transport{Proxy: nil, MaxIdleConns: 16, MaxIdleConnsPerHost: 16, IdleConnTimeout: 90 * time.Second}
	r.client = &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	command := exec.Command(executable, "serve", "--stdio", "--hostname", "127.0.0.1", "--port", "0")
	r.command = command
	command.Dir = opts.CWD
	command.Env = append(env, "OPENCODE_PASSWORD="+r.password)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Stderr = io.Discard
	r.stdin, err = command.StdinPipe()
	if err != nil {
		_ = r.Close()
		return nil, err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		_ = r.Close()
		return nil, err
	}
	if err = command.Start(); err != nil {
		close(r.processDone)
		_ = r.Close()
		return nil, fmt.Errorf("start OpenCode: %w", err)
	}
	go func() {
		r.processErr = command.Wait()
		close(r.processDone)
		if life.Err() == nil {
			r.notifyGap(ErrProcessExited)
		}
		stop()
	}()
	addresses := make(chan string, 1)
	addressErrors := make(chan error, 1)
	go func() {
		reader := bufio.NewReader(stdout)
		size := 0
		for {
			line, err := reader.ReadString('\n')
			size += len(line)
			if size > 65536 {
				addressErrors <- errors.New("OpenCode startup response exceeds limit")
				break
			}
			var value struct {
				URL string `json:"url"`
			}
			if json.Unmarshal([]byte(line), &value) == nil && value.URL != "" {
				addresses <- value.URL
				break
			}
			if err != nil {
				addressErrors <- errors.New("OpenCode closed during startup")
				break
			}
		}
		_, _ = io.Copy(io.Discard, reader)
	}()
	select {
	case address := <-addresses:
		u, err := url.Parse(address)
		if err != nil || u.Scheme != "http" || u.Hostname() != "127.0.0.1" || u.Port() == "" || u.User != nil || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
			_ = r.Close()
			return nil, errors.New("OpenCode returned invalid private address")
		}
		r.URL = u.Scheme + "://" + u.Host
	case err = <-addressErrors:
		_ = r.Close()
		return nil, err
	case <-startup.Done():
		_ = r.Close()
		return nil, startup.Err()
	}
	if err = r.RPC(startup, "refresh", Object{}, nil); err != nil {
		_ = r.Close()
		return nil, err
	}
	go func() { <-life.Done(); _ = r.Close() }()
	return r, nil
}

func (r *Runtime) Request(ctx context.Context, method, path string, body, out any) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := r.ctx.Err(); err != nil {
		return err
	}
	u, err := url.Parse(path)
	if err != nil || u.IsAbs() || u.Host != "" || !strings.HasPrefix(u.Path, "/api/") {
		return errors.New("OpenCode requests must target its private local API")
	}
	if err := r.authorizeSessionRequest(method, u, body); err != nil {
		return err
	}
	q := u.Query()
	if !q.Has("location[directory]") {
		q.Set("location[directory]", r.options.CWD)
	}
	u.RawQuery = q.Encode()
	var data io.Reader
	if body != nil {
		b, e := json.Marshal(body)
		if e != nil {
			return e
		}
		data = bytes.NewReader(b)
	}
	requestCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(r.ctx, cancel)
	defer stop()
	req, err := http.NewRequestWithContext(requestCtx, method, r.URL+u.String(), data)
	if err != nil {
		return err
	}
	req.SetBasicAuth("opencode", r.password)
	req.Header.Set("Content-Type", "application/json")
	res, err := r.client.Do(req)
	if err != nil {
		return fmt.Errorf("OpenCode %s %s transport: %w", method, u.Path, err)
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return &RequestError{res.StatusCode, method, u.Path}
	}
	if res.StatusCode == 204 {
		return nil
	}
	if out == nil {
		_, err = io.Copy(io.Discard, res.Body)
		return err
	}
	var raw json.RawMessage
	if err = json.NewDecoder(io.LimitReader(res.Body, 128<<20)).Decode(&raw); err != nil {
		return fmt.Errorf("OpenCode response JSON: %w", err)
	}
	if original, ok := out.(*RawResponse); ok {
		*original = append((*original)[:0], raw...)
		return nil
	}
	var envelope map[string]json.RawMessage
	if json.Unmarshal(raw, &envelope) == nil {
		if data, ok := envelope["data"]; ok {
			raw = data
		}
	}
	return json.Unmarshal(raw, out)
}

// Restrict the storage API to roots explicitly registered by Mokusei and their
// native descendants. Never enumerate or mutate the user's unrelated sessions.
func (r *Runtime) authorizeSessionRequest(method string, u *url.URL, body any) error {
	id := ""
	switch {
	case u.Path == "/api/session" && method == "GET":
		id = u.Query().Get("parentID")
	case u.Path == "/api/session" || u.Path == "/api/experimental/session/import":
		encoded, err := json.Marshal(body)
		if err != nil {
			return err
		}
		var payload Object
		if err = json.Unmarshal(encoded, &payload); err != nil {
			return err
		}
		id = str(payload["id"])
		if u.Path == "/api/experimental/session/import" {
			id = str(object(payload["info"])["id"])
		}
	case u.Path == "/api/session/active":
		return nil // Live work in this owned server, not stored session inventory.
	case strings.HasPrefix(u.Path, "/api/session/"):
		id, _, _ = strings.Cut(strings.TrimPrefix(u.Path, "/api/session/"), "/")
	case strings.HasPrefix(u.Path, "/api/experimental/session/"):
		id, _, _ = strings.Cut(strings.TrimPrefix(u.Path, "/api/experimental/session/"), "/")
	default:
		return nil
	}
	if !r.bridge.Owns(id) {
		return errors.New("OpenCode session is not owned by this Mokusei runtime")
	}
	return nil
}
func (r *Runtime) RPC(ctx context.Context, method string, input, out any) error {
	var result struct {
		Output json.RawMessage `json:"output"`
	}
	if err := r.Request(ctx, "POST", "/api/rpc/mokusei.harness/"+url.PathEscape(method), Object{"input": input}, &result); err != nil {
		return err
	}
	if out != nil {
		return json.Unmarshal(result.Output, out)
	}
	return nil
}
func (r *Runtime) ConfigureSession(ctx context.Context, id string, config BridgeConfiguration) error {
	revision, err := r.bridge.Configure(id, config)
	if err != nil {
		return err
	}
	var output struct {
		Revisions map[string]int `json:"revisions"`
	}
	if err = r.RPC(ctx, "refresh", Object{}, &output); err != nil {
		return err
	}
	if output.Revisions[id] != revision {
		return errors.New("OpenCode did not acknowledge session configuration")
	}
	return nil
}
func (r *Runtime) Subscribe(onEvent func(Event) error, onGap func(error)) func() {
	r.mu.Lock()
	r.nextListener++
	id := r.nextListener
	r.listeners[id] = listener{onEvent, onGap}
	r.startEventsLocked()
	r.mu.Unlock()
	return func() { r.mu.Lock(); delete(r.listeners, id); r.mu.Unlock() }
}
func (r *Runtime) startEventsLocked() {
	if !r.streamStarted && r.ctx.Err() == nil {
		r.streamStarted = true
		go r.runEvents()
	}
}
func (r *Runtime) EventsReady(ctx context.Context) error {
	r.mu.Lock()
	r.startEventsLocked()
	ready := r.ready
	r.mu.Unlock()
	select {
	case <-ready:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-r.ctx.Done():
		return r.ctx.Err()
	}
}
func (r *Runtime) notifyGap(err error) {
	r.mu.Lock()
	if r.connected {
		r.connected = false
		r.ready = make(chan struct{})
	}
	listeners := make([]listener, 0, len(r.listeners))
	for _, v := range r.listeners {
		listeners = append(listeners, v)
	}
	r.mu.Unlock()
	for _, v := range listeners {
		if v.gap != nil {
			v.gap(err)
		}
	}
}
func (r *Runtime) runEvents() {
	defer close(r.streamDone)
	failures := 0
	for r.ctx.Err() == nil {
		err := r.readEvents()
		if r.ctx.Err() != nil {
			return
		}
		r.mu.Lock()
		healthy := r.connected
		r.mu.Unlock()
		if healthy {
			failures = 0
		}
		r.notifyGap(fmt.Errorf("OpenCode event stream gap; reconcile native history: %w", err))
		failures++
		delay := 250 * time.Millisecond * time.Duration(1<<min(failures, 4))
		select {
		case <-time.After(delay):
		case <-r.ctx.Done():
			return
		}
	}
}
func (r *Runtime) readEvents() error {
	req, err := http.NewRequestWithContext(r.ctx, "GET", r.URL+"/api/event", nil)
	if err != nil {
		return err
	}
	req.SetBasicAuth("opencode", r.password)
	req.Header.Set("Accept", "text/event-stream")
	res, err := r.client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return &RequestError{res.StatusCode, "GET", "/api/event"}
	}
	return readSSE(res.Body, func(raw []byte) error {
		var event Event
		if err := json.Unmarshal(raw, &event); err != nil {
			return err
		}
		if event.Type == "session.created" {
			r.bridge.TrackChild(eventSession(event), str(event.Data["parentID"]))
		}
		r.mu.Lock()
		if event.Type == "server.connected" && !r.connected {
			r.connected = true
			close(r.ready)
		}
		listeners := make([]listener, 0, len(r.listeners))
		for _, v := range r.listeners {
			listeners = append(listeners, v)
		}
		r.mu.Unlock()
		for _, v := range listeners {
			if v.event != nil {
				if err := v.event(event); err != nil {
					return err
				}
			}
		}
		return nil
	})
}
func readSSE(reader io.Reader, consume func([]byte) error) error {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 4096), 16<<20)
	var data []string
	flush := func() error {
		if len(data) == 0 {
			return nil
		}
		joined := strings.Join(data, "\n")
		data = nil
		return consume([]byte(joined))
	}
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			if err := flush(); err != nil {
				return err
			}
		} else if strings.HasPrefix(line, "data:") {
			data = append(data, strings.TrimPrefix(strings.TrimPrefix(line, "data:"), " "))
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	if err := flush(); err != nil {
		return err
	}
	return io.EOF
}
func (r *Runtime) Close() error {
	r.closeOnce.Do(func() {
		r.cancel()
		if r.bridge != nil {
			r.bridge.Revoke()
		}
		r.mu.Lock()
		streamStarted := r.streamStarted
		r.mu.Unlock()
		if streamStarted {
			<-r.streamDone
		}
		stopped := true
		if r.command != nil && r.command.Process != nil {
			_ = r.stdin.Close()
			wait := func() bool {
				select {
				case <-r.processDone:
					return true
				case <-time.After(2 * time.Second):
					return false
				}
			}
			if !wait() {
				_ = syscall.Kill(-r.command.Process.Pid, syscall.SIGTERM)
				if !wait() {
					_ = syscall.Kill(-r.command.Process.Pid, syscall.SIGKILL)
					stopped = wait()
				}
			}
		}
		if stopped && r.command != nil && r.command.Process != nil {
			if err := processgroup.DrainAfterExit(r.command.Process.Pid); err != nil {
				stopped = false
				r.closeErr = err
			}
		}
		if !stopped {
			r.closeErr = errors.Join(r.closeErr, errors.New("OpenCode process did not exit after termination"))
		}
		if r.client != nil {
			r.client.CloseIdleConnections()
		}
		if r.bridge != nil {
			r.closeErr = errors.Join(r.closeErr, r.bridge.Close(!stopped))
		}
		if stopped && r.cleanup != nil {
			r.closeErr = errors.Join(r.closeErr, r.cleanup())
		}
	})
	return r.closeErr
}

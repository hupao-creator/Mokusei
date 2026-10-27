package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

// runtimeClient deliberately does not reconnect. A reset or stream gap makes
// behavioral evidence incomplete and must remain an infrastructure error.
type runtimeClient struct {
	connection  profile.Connection
	http        *http.Client
	ctx         context.Context
	cancel      context.CancelFunc
	mu          sync.Mutex
	state       model.AppState
	hydrated    bool
	queued      []model.StateMutation
	streamError error
	streamDone  chan struct{}
	closeOnce   sync.Once
}

func newRuntimeClient(ctx context.Context, connection profile.Connection) *runtimeClient {
	ctx, cancel := context.WithCancel(ctx)
	return &runtimeClient{connection: connection, ctx: ctx, cancel: cancel, streamDone: make(chan struct{}), http: &http.Client{Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}
func (c *runtimeClient) request(ctx context.Context, method, path string, body io.Reader) (*http.Response, error) {
	request, e := http.NewRequestWithContext(ctx, method, fmt.Sprintf("http://127.0.0.1:%d%s", c.connection.Port, path), body)
	if e != nil {
		return nil, e
	}
	request.Header.Set("Authorization", "Bearer "+c.connection.Token)
	request.Header.Set("X-Mokusei-Protocol", strconv.Itoa(transport.ProtocolVersion))
	request.Header.Set("X-Mokusei-Epoch", c.connection.Epoch)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	return c.http.Do(request)
}
func (c *runtimeClient) invoke(ctx context.Context, channel string, args []any, target any) error {
	id, e := transport.CreateCommandID()
	if e != nil {
		return e
	}
	return c.invokeID(ctx, id, channel, args, target)
}
func (c *runtimeClient) invokeID(ctx context.Context, id, channel string, args []any, target any) error {
	if args == nil {
		args = []any{}
	}
	body, e := json.Marshal(map[string]any{"commandId": id, "args": args})
	if e != nil {
		return e
	}
	response, e := c.request(ctx, http.MethodPost, "/invoke/"+url.PathEscape(channel), bytes.NewReader(body))
	if e != nil {
		return e
	}
	defer response.Body.Close()
	data, e := io.ReadAll(io.LimitReader(response.Body, transport.MaxResponseBytes+1))
	if e != nil {
		return e
	}
	if len(data) > transport.MaxResponseBytes {
		return errors.New("Runtime response exceeds protocol limit")
	}
	var result transport.Result
	if e = json.Unmarshal(data, &result); e != nil {
		return fmt.Errorf("Invalid runtime response: %w", e)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 || !result.OK {
		if result.Error != nil {
			return fmt.Errorf("Runtime %s: %s", result.Error.Code, result.Error.Message)
		}
		return fmt.Errorf("Runtime HTTP %d", response.StatusCode)
	}
	if target != nil {
		return json.Unmarshal(result.Value, target)
	}
	return nil
}
func (c *runtimeClient) start() error {
	response, e := c.request(c.ctx, http.MethodGet, "/events", nil)
	if e != nil {
		close(c.streamDone)
		return e
	}
	if response.StatusCode != http.StatusOK {
		response.Body.Close()
		close(c.streamDone)
		return fmt.Errorf("Runtime event stream HTTP %d", response.StatusCode)
	}
	hello := make(chan error, 1)
	go c.readStream(response.Body, hello)
	select {
	case e := <-hello:
		if e != nil {
			return e
		}
	case <-c.ctx.Done():
		return c.ctx.Err()
	}
	var state model.AppState
	if e = c.invoke(c.ctx, "state:load", nil, &state); e != nil {
		return e
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.streamError != nil {
		return c.streamError
	}
	c.state = state
	for _, mutation := range c.queued {
		if mutation.Revision <= state.Revision {
			continue
		}
		if e = applyMutation(&c.state, mutation); e != nil {
			c.streamError = e
			return e
		}
	}
	c.queued = nil
	c.hydrated = true
	return nil
}
func (c *runtimeClient) readStream(body io.ReadCloser, hello chan<- error) {
	defer close(c.streamDone)
	defer body.Close()
	scanner := bufio.NewScanner(body)
	scanner.Buffer(make([]byte, 64*1024), transport.MaxEventBytes+1)
	connected := false
	fail := func(e error) {
		if !connected {
			hello <- e
			connected = true
		}
		c.reject(e)
	}
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var event struct {
			Type            string          `json:"type"`
			Epoch           string          `json:"epoch"`
			ProtocolVersion int             `json:"protocolVersion"`
			ClientID        string          `json:"clientId"`
			Mutation        json.RawMessage `json:"mutation"`
		}
		if e := json.Unmarshal(line, &event); e != nil {
			fail(fmt.Errorf("Invalid runtime event: %w", e))
			return
		}
		if event.Epoch != c.connection.Epoch {
			fail(errors.New("Runtime epoch changed; event evidence is incomplete"))
			return
		}
		if !connected {
			if event.Type != "hello" || event.ProtocolVersion != transport.ProtocolVersion || event.ClientID == "" {
				fail(errors.New("Runtime event stream did not begin with a valid hello"))
				return
			}
			connected = true
			hello <- nil
			continue
		}
		switch event.Type {
		case "hello", "reset":
			fail(errors.New("Runtime reset during observation; event evidence is incomplete"))
			return
		case "stopping":
			fail(errors.New("Runtime stopped during observation"))
			return
		case "mutation":
			var mutation model.StateMutation
			if e := json.Unmarshal(event.Mutation, &mutation); e != nil {
				fail(fmt.Errorf("Invalid runtime mutation: %w", e))
				return
			}
			c.mu.Lock()
			var e error
			if !c.hydrated {
				if len(c.queued) >= 4096 {
					e = errors.New("Runtime hydration mutation buffer exceeded its limit")
				} else {
					c.queued = append(c.queued, mutation)
				}
			} else if mutation.Revision > c.state.Revision {
				e = applyMutation(&c.state, mutation)
			}
			c.mu.Unlock()
			if e != nil {
				fail(e)
				return
			}
		case "overview-filter", "thread-content": // These UI leases were never requested by this observer.
		default:
			fail(fmt.Errorf("Unknown runtime event %q; event evidence is incomplete", event.Type))
			return
		}
	}
	if c.ctx.Err() != nil {
		return
	}
	if e := scanner.Err(); e != nil {
		fail(fmt.Errorf("Runtime event stream disconnected: %w", e))
	} else {
		fail(errors.New("Runtime event stream disconnected during observation"))
	}
}
func (c *runtimeClient) reject(e error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.streamError == nil {
		c.streamError = e
	}
}
func (c *runtimeClient) snapshot() (model.AppState, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.streamError != nil {
		return model.AppState{}, c.streamError
	}
	if !c.hydrated {
		return model.AppState{}, errors.New("Runtime snapshot unavailable")
	}
	data, e := json.Marshal(c.state)
	if e != nil {
		return model.AppState{}, e
	}
	var snapshot model.AppState
	e = json.Unmarshal(data, &snapshot)
	return snapshot, e
}
func (c *runtimeClient) close() {
	c.closeOnce.Do(func() { c.cancel(); c.http.CloseIdleConnections(); <-c.streamDone })
}
func applyMutation(state *model.AppState, mutation model.StateMutation) error {
	if mutation.Type != "state-patched" || mutation.BaseRevision != state.Revision || mutation.Revision <= mutation.BaseRevision {
		return fmt.Errorf("Runtime mutation gap: state=%d base=%d next=%d type=%s", state.Revision, mutation.BaseRevision, mutation.Revision, mutation.Type)
	}
	threads, e := applyCollection(state.Threads, mutation.Threads, func(v model.ThreadRecord) string { return v.ID })
	if e != nil {
		return e
	}
	applications, e := applyCollection(state.ApplicationThreads, mutation.ApplicationThreads, func(v model.ApplicationThread) string { return v.ID })
	if e != nil {
		return e
	}
	state.Threads = threads
	state.ApplicationThreads = applications
	if mutation.DefaultCwd != nil {
		state.DefaultCwd = *mutation.DefaultCwd
	}
	if mutation.Executions != nil {
		state.Executions = *mutation.Executions
	}
	if mutation.AgentRuns != nil {
		state.AgentRuns = *mutation.AgentRuns
	}
	if mutation.TagRedirects != nil {
		state.TagRedirects = *mutation.TagRedirects
	}
	if mutation.Settings != nil {
		state.Settings = *mutation.Settings
	}
	if mutation.SettingsRevision != nil {
		state.SettingsRevision = *mutation.SettingsRevision
	}
	if mutation.Plugins != nil {
		state.Plugins = *mutation.Plugins
	}
	state.Revision = mutation.Revision
	return nil
}
func applyCollection[T any](original []T, patch *model.CollectionPatch[T], id func(T) string) ([]T, error) {
	if patch == nil {
		return original, nil
	}
	values := map[string]T{}
	order := []string{}
	removed := map[string]bool{}
	for _, key := range patch.RemovedIDs {
		removed[key] = true
	}
	for _, value := range original {
		key := id(value)
		if !removed[key] {
			values[key] = value
			order = append(order, key)
		}
	}
	seen := map[string]bool{}
	for _, value := range patch.Upserts {
		key := id(value)
		if key == "" || seen[key] {
			return nil, errors.New("Invalid runtime collection upserts")
		}
		seen[key] = true
		if _, exists := values[key]; !exists {
			order = append(order, key)
		}
		values[key] = value
	}
	if patch.Order != nil {
		order = *patch.Order
	}
	result := make([]T, 0, len(values))
	seen = map[string]bool{}
	for _, key := range order {
		value, exists := values[key]
		if !exists || seen[key] {
			return nil, errors.New("Invalid runtime collection order")
		}
		seen[key] = true
		result = append(result, value)
	}
	if len(result) != len(values) {
		return nil, errors.New("Runtime collection order omitted records")
	}
	return result, nil
}

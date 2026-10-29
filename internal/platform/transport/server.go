package transport

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
)

type Options struct {
	Profile     profile.Profile
	Epoch       string
	Host        Host
	Overview    *OverviewBroker
	RequestStop func(context.Context) error
}
type Server struct {
	Connection        profile.Connection
	mu                sync.Mutex
	accepting         bool
	closed            bool
	activeRequests    int
	sessionRequests   int
	inFlightBodyBytes int64
	clients           map[string]*eventStream
	sockets           map[net.Conn]bool
	stopSockets       map[net.Conn]bool
	listener          net.Listener
	http              *http.Server
	host              Host
	overview          *OverviewBroker
	content           *contentServer
	commands          *commandExecutor
	stop              func(context.Context) error
	unsubscribe       func()
	lifecycle         context.Context
	cancel            context.CancelFunc
	revokeOnce        sync.Once
	fileWorkers       fileWorkers
}
type connectionContextKey struct{}

func Start(options Options) (*Server, error) {
	if options.Host == nil || options.Epoch == "" {
		return nil, errors.New("transport requires a Host and ownership epoch")
	}
	token, err := randomToken()
	if err != nil {
		return nil, err
	}
	lifecycle, cancel := context.WithCancel(context.Background())
	commands, err := newCommandExecutor(options.Host, options.Profile.ReceiptsPath, lifecycle)
	if err != nil {
		cancel()
		return nil, err
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		cancel()
		return nil, err
	}
	overview := options.Overview
	if overview == nil {
		overview = NewOverviewBroker(10 * time.Second)
	}
	s := &Server{accepting: true, clients: make(map[string]*eventStream), sockets: make(map[net.Conn]bool), stopSockets: make(map[net.Conn]bool), listener: listener, host: options.Host, overview: overview, commands: commands, stop: options.RequestStop, lifecycle: lifecycle, cancel: cancel}
	s.Connection = profile.Connection{Port: listener.Addr().(*net.TCPAddr).Port, Token: token, Epoch: options.Epoch, ProtocolVersion: ProtocolVersion, PID: os.Getpid(), DataDir: options.Profile.DataDir}
	s.content = newContentServer(lifecycle, options.Host, s.client)
	s.http = &http.Server{
		Handler: http.HandlerFunc(s.serveHTTP), ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second, IdleTimeout: 5 * time.Second, MaxHeaderBytes: 16 * 1024,
		ConnContext: func(ctx context.Context, conn net.Conn) context.Context {
			return context.WithValue(ctx, connectionContextKey{}, conn)
		},
		ConnState: func(conn net.Conn, state http.ConnState) {
			s.mu.Lock()
			defer s.mu.Unlock()
			switch state {
			case http.StateNew:
				if s.closed || len(s.sockets) >= 64 {
					conn.Close()
					return
				}
				s.sockets[conn] = true
			case http.StateClosed, http.StateHijacked:
				delete(s.sockets, conn)
				delete(s.stopSockets, conn)
			}
		},
	}
	s.unsubscribe = options.Host.SubscribeMutations(func(mutation json.RawMessage) {
		if !json.Valid(mutation) {
			return
		}
		s.broadcast(map[string]any{"type": "mutation", "epoch": s.Connection.Epoch, "mutation": mutation})
		s.content.publish()
	})
	go func() { _ = s.http.Serve(listener) }()
	return s, nil
}
func (s *Server) Overview() *OverviewBroker { return s.overview }
func (s *Server) client(id string) *eventStream {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.clients[id]
}
func (s *Server) isAccepting() bool { s.mu.Lock(); defer s.mu.Unlock(); return s.accepting }
func (s *Server) broadcast(event any) {
	body, err := encodeEvent(event)
	if err != nil {
		return
	}
	s.mu.Lock()
	clients := make([]*eventStream, 0, len(s.clients))
	for _, client := range s.clients {
		clients = append(clients, client)
	}
	s.mu.Unlock()
	for _, client := range clients {
		if err = client.enqueue(body, ""); err != nil {
			client.abort()
		}
	}
}
func (s *Server) serveHTTP(w http.ResponseWriter, r *http.Request) {
	// Keep panics confined to their request. Durable write panics are recorded by
	// ReceiptStore; malformed host read responses cannot kill the HTTP server.
	defer func() {
		if recover() != nil {
			s.send(w, http.StatusInternalServerError, resultFailure(model.NewError("COMMAND_FAILED", "Runtime request failed")))
		}
	}()
	expected := []byte("Bearer " + s.Connection.Token)
	supplied := []byte(r.Header.Get("Authorization"))
	_, hasOrigin := r.Header["Origin"]
	if hasOrigin || len(supplied) != len(expected) || subtle.ConstantTimeCompare(supplied, expected) != 1 {
		w.Header().Set("Connection", "close")
		s.send(w, 401, resultFailure(model.NewError("UNAUTHORIZED", "Runtime authentication required")))
		return
	}
	if r.Header.Get("X-Mokusei-Protocol") != fmt.Sprint(ProtocolVersion) {
		s.send(w, 409, resultFailure(model.NewError("PROTOCOL_MISMATCH", "Runtime protocol version does not match this client")))
		return
	}
	if r.Header.Get("X-Mokusei-Epoch") != s.Connection.Epoch {
		s.send(w, 409, resultFailure(model.NewError("STALE_EPOCH", "Runtime service instance has changed")))
		return
	}
	path := r.URL.EscapedPath()
	if r.URL.RawQuery != "" {
		s.send(w, 404, resultFailure(model.NewError("UNKNOWN_COMMAND", "Unknown runtime command")))
		return
	}
	if r.Method == http.MethodPost && path == "/commands/receipt" {
		s.serveReceiptQuery(w, r)
		return
	}
	if r.Method == http.MethodGet && path == "/health" {
		s.mu.Lock()
		status := "stopping"
		if s.accepting {
			status = "running"
		}
		s.mu.Unlock()
		health := map[string]any{"port": s.Connection.Port, "epoch": s.Connection.Epoch, "protocolVersion": ProtocolVersion, "pid": s.Connection.PID, "dataDir": s.Connection.DataDir, "status": status}
		s.send(w, 200, health)
		return
	}
	if r.Method == http.MethodPost && path == "/stop" {
		w.Header().Set("Connection", "close")
		conn, _ := r.Context().Value(connectionContextKey{}).(net.Conn)
		s.mu.Lock()
		if conn != nil {
			s.stopSockets[conn] = true
		}
		s.mu.Unlock()
		defer func() { s.mu.Lock(); delete(s.stopSockets, conn); s.mu.Unlock() }()
		if s.stop == nil {
			s.send(w, 500, resultFailure(model.NewError("SHUTDOWN_FAILED", "Runtime shutdown handler is unavailable")))
			return
		}
		// The stop response is kept alive while host cleanup interrupts admitted
		// work, drains receipts, and closes every other runtime connection.
		if err := s.stop(context.WithoutCancel(r.Context())); err != nil {
			s.send(w, 500, resultFailure(model.NewError("SHUTDOWN_FAILED", err.Error())))
		} else {
			s.send(w, 200, Result{OK: true})
		}
		return
	}
	if !s.isAccepting() {
		s.send(w, 503, resultFailure(model.NewError("SERVICE_STOPPING", "Runtime is stopping")))
		return
	}
	if s.serveFiles(w, r) {
		return
	}
	if r.Method == http.MethodGet && path == "/events" {
		s.events(w, r)
		return
	}
	overviewEndpoint := path == "/overview/context" || path == "/overview/ack" || path == "/overview/claim"
	contentEndpoint := path == "/thread-content/subscription"
	channel := ""
	if strings.HasPrefix(path, "/invoke/") {
		encoded := strings.TrimPrefix(path, "/invoke/")
		if !strings.Contains(encoded, "/") {
			channel, _ = url.PathUnescape(encoded)
		}
	}
	if r.Method != http.MethodPost || (!overviewEndpoint && !contentEndpoint && (channel == "" || !s.host.HasChannel(channel))) {
		s.send(w, 404, resultFailure(model.NewError("UNKNOWN_COMMAND", "Unknown runtime command")))
		return
	}
	// Session controls release content and maintain the renderer lease. Slow
	// native queries must not consume every slot needed to retire those owners.
	sessionRequest := overviewEndpoint || contentEndpoint
	s.mu.Lock()
	active, maximum := &s.activeRequests, maxActiveRequests
	if sessionRequest {
		active, maximum = &s.sessionRequests, maxSessionRequests
	}
	if *active >= maximum {
		s.mu.Unlock()
		s.send(w, 503, resultFailure(model.NewError("CAPACITY_EXHAUSTED", "Runtime request capacity reached")))
		return
	}
	*active++
	s.mu.Unlock()
	reserved := int64(0)
	defer func() {
		s.mu.Lock()
		*active--
		s.inFlightBodyBytes -= reserved
		s.mu.Unlock()
		r.Body.Close()
	}()
	limit := MaxRequestBytes
	if overviewEndpoint || contentEndpoint {
		limit = MaxOverviewBytes
	}
	body, err := s.readBody(r, limit, &reserved)
	if err != nil {
		s.send(w, 400, resultFailure(err))
		return
	}
	if !s.isAccepting() {
		s.send(w, 503, resultFailure(model.NewError("SERVICE_STOPPING", "Runtime is stopping")))
		return
	}
	if contentEndpoint {
		err = s.content.update(body)
		if err != nil {
			s.send(w, 400, resultFailure(err))
		} else {
			s.send(w, 200, Result{OK: true})
		}
		return
	}
	if overviewEndpoint {
		value, executeErr := s.overview.Execute(path, body)
		if executeErr != nil {
			s.send(w, 400, resultFailure(executeErr))
		} else {
			s.send(w, 200, resultSuccess(value))
		}
		return
	}
	result, err := s.commands.execute(r.Context(), channel, body)
	if err != nil {
		s.send(w, 400, resultFailure(err))
		return
	}
	s.send(w, 200, result)
}
func (s *Server) send(w http.ResponseWriter, status int, value any) {
	body, err := json.Marshal(value)
	if err != nil {
		status = 500
		body, _ = json.Marshal(resultFailure(model.NewError("INVALID_RESPONSE", "Runtime response could not be serialized")))
	}
	if len(body) > MaxResponseBytes {
		status = 413
		body, _ = json.Marshal(resultFailure(model.NewError("RESPONSE_TOO_LARGE", "Runtime response exceeds the transport limit")))
	}
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(30 * time.Second))
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}
func (s *Server) readBody(r *http.Request, limit int, reserved *int64) ([]byte, error) {
	reserve := func(n int64) error {
		if n <= 0 {
			return nil
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.inFlightBodyBytes+n > maxInFlightBodyBytes {
			return model.NewError("CAPACITY_EXHAUSTED", "Runtime in-flight request body capacity reached")
		}
		s.inFlightBodyBytes += n
		*reserved += n
		return nil
	}
	if r.ContentLength > int64(limit) {
		return nil, model.NewError("REQUEST_TOO_LARGE", "Runtime request exceeds the transport limit")
	}
	if err := reserve(r.ContentLength); err != nil {
		return nil, err
	}
	var buffer bytes.Buffer
	chunk := make([]byte, 64*1024)
	for {
		n, err := r.Body.Read(chunk)
		if n > 0 {
			total := buffer.Len() + n
			if total > limit {
				return nil, model.NewError("REQUEST_TOO_LARGE", "Runtime request exceeds the transport limit")
			}
			if int64(total) > *reserved {
				if reserveErr := reserve(int64(total) - *reserved); reserveErr != nil {
					return nil, reserveErr
				}
			}
			buffer.Write(chunk[:n])
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, model.NewError("INVALID_REQUEST", "Runtime request body could not be read")
		}
	}
	if !json.Valid(buffer.Bytes()) {
		return nil, model.NewError("INVALID_REQUEST", "Runtime request must contain a JSON value")
	}
	return buffer.Bytes(), nil
}
func (s *Server) Revoke() {
	s.revokeOnce.Do(func() {
		s.mu.Lock()
		s.accepting = false
		clients := make([]*eventStream, 0, len(s.clients))
		for _, client := range s.clients {
			clients = append(clients, client)
		}
		s.mu.Unlock()
		s.commands.revoke()
		// Drain runs before Close, so admitted Host calls must observe service
		// cancellation here while /health and the /stop response remain alive.
		s.cancel()
		s.fileWorkers.close()
		s.overview.Close()
		s.content.close()
		if s.unsubscribe != nil {
			s.unsubscribe()
		}
		body, _ := encodeEvent(map[string]any{"type": "stopping", "epoch": s.Connection.Epoch})
		for _, client := range clients {
			client.finish(body)
		}
	})
}

// Drain joins admitted commands and content workers after Revoke. A timed-out
// caller may invoke Drain again to await the same outstanding work.
func (s *Server) Drain(ctx context.Context) error {
	return errors.Join(s.commands.drain(ctx), s.content.wait(ctx), s.fileWorkers.wait(ctx))
}

// Finish joins HTTP response writers after lifecycle cleanup. Call outside the
// /stop handler, after Close: Go process exit otherwise truncates its response.
func (s *Server) Finish(ctx context.Context) error {
	err := s.http.Shutdown(ctx)
	// Close already retired the listener. Shutdown can still find its wrapper
	// before Serve removes it; after joining connections that is a successful drain.
	if errors.Is(err, net.ErrClosed) {
		return nil
	}
	return err
}

// Close stops admission and connections synchronously, except the /stop socket
// currently waiting for host shutdown. That socket closes after its response.
func (s *Server) Close(ctx context.Context) error {
	s.Revoke()
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return errors.Join(s.content.wait(ctx), s.fileWorkers.wait(ctx))
	}
	s.closed = true
	sockets := make([]net.Conn, 0, len(s.sockets))
	for conn := range s.sockets {
		if !s.stopSockets[conn] {
			sockets = append(sockets, conn)
		}
	}
	s.mu.Unlock()
	err := s.listener.Close()
	for _, conn := range sockets {
		_ = conn.Close()
	}
	if errors.Is(err, net.ErrClosed) {
		err = nil
	}
	return errors.Join(err, s.content.wait(ctx), s.fileWorkers.wait(ctx))
}

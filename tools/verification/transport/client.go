package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type apiClient struct {
	connection profile.Connection
	base       string
	client     *http.Client
	transport  *http.Transport
}

func newAPI(connection profile.Connection) *apiClient {
	pool := &http.Transport{MaxIdleConns: 64, MaxIdleConnsPerHost: 64, IdleConnTimeout: time.Second}
	return &apiClient{connection: connection, base: fmt.Sprintf("http://127.0.0.1:%d", connection.Port), client: &http.Client{Transport: pool}, transport: pool}
}

func (a *apiClient) close() { a.transport.CloseIdleConnections() }

func (a *apiClient) authorize(request *http.Request) {
	request.Header.Set("Authorization", "Bearer "+a.connection.Token)
	request.Header.Set("X-Mokusei-Protocol", strconv.Itoa(transport.ProtocolVersion))
	request.Header.Set("X-Mokusei-Epoch", a.connection.Epoch)
}

type reply struct {
	status int
	object map[string]any
	err    error
}

func (r reply) requireStatus(status int) {
	must(r.err)
	check(r.status == status, fmt.Sprintf("HTTP status %d, expected %d: %v", r.status, status, r.object))
}

func (r reply) requireFailure(status int, code string) {
	r.requireStatus(status)
	failure, ok := r.object["error"].(map[string]any)
	check(ok && failure["code"] == code, fmt.Sprintf("expected %s failure, received %v", code, r.object))
}

func (a *apiClient) request(ctx context.Context, method, path string, value any, adjust func(*http.Request)) reply {
	var body io.Reader
	if value != nil {
		raw, err := json.Marshal(value)
		if err != nil {
			return reply{err: err}
		}
		body = bytes.NewReader(raw)
	}
	request, err := http.NewRequestWithContext(ctx, method, a.base+path, body)
	if err != nil {
		return reply{err: err}
	}
	a.authorize(request)
	if adjust != nil {
		adjust(request)
	}
	response, err := a.client.Do(request)
	if err != nil {
		return reply{err: err}
	}
	defer response.Body.Close()
	var object map[string]any
	err = json.NewDecoder(io.LimitReader(response.Body, transport.MaxResponseBytes+1)).Decode(&object)
	return reply{status: response.StatusCode, object: object, err: err}
}

type eventResult struct {
	value map[string]any
	err   error
}

type eventConnection struct {
	id     string
	queue  chan eventResult
	done   chan struct{}
	cancel context.CancelFunc
	body   io.ReadCloser
}

func (a *apiClient) events(ctx context.Context) *eventConnection {
	ctx, cancel := context.WithCancel(ctx)
	request, err := http.NewRequestWithContext(ctx, "GET", a.base+"/events", nil)
	must(err)
	a.authorize(request)
	response, err := a.client.Do(request)
	if err != nil {
		cancel()
		panic(err)
	}
	check(response.StatusCode == 200, "event stream admission failed")
	connection := &eventConnection{queue: make(chan eventResult, 128), done: make(chan struct{}), cancel: cancel, body: response.Body}
	go func() {
		defer close(connection.done)
		defer close(connection.queue)
		scanner := bufio.NewScanner(response.Body)
		scanner.Buffer(make([]byte, 4096), transport.MaxEventBytes)
		for scanner.Scan() {
			if len(scanner.Bytes()) == 0 {
				continue
			}
			var value map[string]any
			err := json.Unmarshal(scanner.Bytes(), &value)
			select {
			case connection.queue <- eventResult{value: value, err: err}:
			case <-ctx.Done():
				return
			}
		}
		if err := scanner.Err(); err != nil && ctx.Err() == nil {
			select {
			case connection.queue <- eventResult{err: err}:
			case <-ctx.Done():
			}
		}
	}()
	hello := connection.next(ctx)
	check(hello["type"] == "hello" && hello["epoch"] == a.connection.Epoch && hello["protocolVersion"] == float64(transport.ProtocolVersion), "invalid NDJSON hello")
	connection.id, _ = hello["clientId"].(string)
	check(connection.id != "", "event stream has no client identity")
	return connection
}

func (c *eventConnection) close() {
	c.cancel()
	_ = c.body.Close()
	<-c.done
}

func (c *eventConnection) next(ctx context.Context) map[string]any {
	select {
	case item, open := <-c.queue:
		check(open, "NDJSON stream ended before its expected event")
		must(item.err)
		return item.value
	case <-ctx.Done():
		panic(fmt.Errorf("waiting for NDJSON event: %w", ctx.Err()))
	}
}

// headerRequest reserves a declared body budget without allocating or sending
// that body. A 100 Continue response proves the server reached its body read.
func (a *apiClient) headerRequest(ctx context.Context, path string, length int64, expectContinue bool) (net.Conn, *bufio.Reader, *http.Response) {
	connection, err := (&net.Dialer{}).DialContext(ctx, "tcp4", fmt.Sprintf("127.0.0.1:%d", a.connection.Port))
	must(err)
	deadline := time.Now().Add(5 * time.Second)
	if end, exists := ctx.Deadline(); exists && end.Before(deadline) {
		deadline = end
	}
	must(connection.SetDeadline(deadline))
	expect := ""
	if expectContinue {
		expect = "Expect: 100-continue\r\n"
	}
	_, err = fmt.Fprintf(connection, "POST %s HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\nX-Mokusei-Protocol: %d\r\nX-Mokusei-Epoch: %s\r\nContent-Length: %d\r\n%sConnection: close\r\n\r\n", path, a.connection.Token, transport.ProtocolVersion, a.connection.Epoch, length, expect)
	must(err)
	reader := bufio.NewReader(connection)
	response, err := http.ReadResponse(reader, &http.Request{Method: "POST"})
	if err != nil {
		connection.Close()
		panic(err)
	}
	return connection, reader, response
}

func rawReply(response *http.Response) reply {
	defer response.Body.Close()
	var object map[string]any
	err := json.NewDecoder(io.LimitReader(response.Body, 16384)).Decode(&object)
	return reply{status: response.StatusCode, object: object, err: err}
}

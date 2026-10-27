package transport

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

type queuedEvent struct {
	body         []byte
	subscription string
}
type eventStream struct {
	epoch   string
	mu      sync.Mutex
	queue   []queuedEvent
	bytes   int
	wake    chan struct{}
	done    chan struct{}
	aborted bool
	ending  bool
}

func newEventStream(epoch string) *eventStream {
	return &eventStream{epoch: epoch, wake: make(chan struct{}, 1), done: make(chan struct{})}
}
func encodeEvent(event any) ([]byte, error) {
	data, err := json.Marshal(event)
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}
func (c *eventStream) signal() {
	select {
	case c.wake <- struct{}{}:
	default:
	}
}
func (c *eventStream) enqueue(body []byte, subscription string) error {
	limit := MaxEventBytes
	if subscription != "" {
		limit = contentWriteLimit
	}
	return c.enqueueWithLimit(body, subscription, limit)
}
func (c *eventStream) enqueueWithLimit(body []byte, subscription string, limit int) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.aborted || c.ending {
		return errors.New("event stream closed")
	}
	if len(body) > limit {
		return model.NewError("CONTENT_TOO_LARGE", "This conversation turn exceeds the content transport limit")
	}
	if c.bytes+len(body) > limit {
		return model.NewError("CONTENT_BACKPRESSURE", "对话内容加载暂时繁忙，请重试。")
	}
	c.queue = append(c.queue, queuedEvent{body: bytes.Clone(body), subscription: subscription})
	c.bytes += len(body)
	c.signal()
	return nil
}
func (c *eventStream) cancelContent(id string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	queue := c.queue[:0]
	for _, item := range c.queue {
		if item.subscription == id {
			c.bytes -= len(item.body)
		} else {
			queue = append(queue, item)
		}
	}
	for index := len(queue); index < len(c.queue); index++ {
		c.queue[index] = queuedEvent{}
	}
	c.queue = queue
}
func (c *eventStream) pop() ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.aborted {
		return nil, true
	}
	if len(c.queue) == 0 {
		return nil, c.ending
	}
	item := c.queue[0]
	c.queue[0] = queuedEvent{}
	c.queue = c.queue[1:]
	c.bytes -= len(item.body)
	return item.body, false
}
func (c *eventStream) finish(body []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ending || c.aborted {
		return
	}
	if c.bytes+len(body) <= MaxEventBytes {
		c.queue = append(c.queue, queuedEvent{body: body})
		c.bytes += len(body)
	}
	c.ending = true
	c.signal()
}
func (c *eventStream) abort() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.aborted {
		return
	}
	c.aborted = true
	c.queue = nil
	c.bytes = 0
	close(c.done)
	c.signal()
}
func (s *Server) events(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	if !s.accepting || len(s.clients) >= maxClients {
		s.mu.Unlock()
		s.send(w, 503, resultFailure(model.NewError("TOO_MANY_CLIENTS", "Runtime subscription capacity reached")))
		return
	}
	// Reserve capacity through broker connection and hello creation. Connect does
	// not synchronously deliver a filter, so this lock cannot reenter broadcast.
	client := newEventStream(s.Connection.Epoch)
	clientID, err := s.overview.Connect(func(request any) error {
		body, encodeErr := encodeEvent(map[string]any{"type": "overview-filter", "epoch": s.Connection.Epoch, "request": request})
		if encodeErr != nil {
			return encodeErr
		}
		return client.enqueue(body, "")
	})
	if err != nil {
		s.mu.Unlock()
		s.send(w, 503, resultFailure(err))
		return
	}
	hello, _ := encodeEvent(map[string]any{"type": "hello", "epoch": s.Connection.Epoch, "protocolVersion": ProtocolVersion, "clientId": clientID})
	_ = client.enqueue(hello, "")
	s.clients[clientID] = client
	s.content.connect(clientID)
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.clients, clientID)
		s.mu.Unlock()
		s.overview.Disconnect(clientID)
		s.content.disconnect(clientID)
		client.abort()
	}()
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	controller := http.NewResponseController(w)
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	write := func(body []byte) bool {
		if err = controller.SetWriteDeadline(time.Now().Add(30 * time.Second)); err != nil {
			return false
		}
		if _, err = w.Write(body); err != nil {
			return false
		}
		return controller.Flush() == nil
	}
	for {
		body, done := client.pop()
		if done {
			return
		}
		if body != nil {
			if !write(body) {
				return
			}
			continue
		}
		select {
		case <-r.Context().Done():
			return
		case <-client.done:
			return
		case <-client.wake:
		case <-ticker.C:
			if !write([]byte{'\n'}) {
				return
			}
		}
	}
}

func (c *eventStream) encodeContent(event any) ([]byte, error) {
	return encodeEvent(map[string]any{"type": "thread-content", "epoch": c.epoch, "event": event})
}
func (c *eventStream) deliverContentError(subscription, message string) {
	if len(message) > 4000 {
		message = message[:4000]
	}
	body, err := c.encodeContent(map[string]any{"type": "error", "subscriptionId": subscription, "message": message})
	if err != nil || c.enqueueWithLimit(body, subscription, MaxEventBytes) != nil {
		c.abort()
	}
}

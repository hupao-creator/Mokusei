package threadvoice

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type Request struct {
	ThreadID string `json:"threadId"`
	Request  Action `json:"request"`
}
type Action struct {
	Action      string `json:"action"`
	RequestID   string `json:"requestId,omitempty"`
	SessionID   string `json:"sessionId,omitempty"`
	OwnershipID string `json:"ownershipId,omitempty"`
	SDP         string `json:"sdp,omitempty"`
	After       int64  `json:"after,omitempty"`
}
type Result struct {
	SessionID   string                           `json:"sessionId,omitempty"`
	OwnershipID string                           `json:"ownershipId,omitempty"`
	SDP         string                           `json:"sdp,omitempty"`
	Events      *[]plugin.VoiceEvent             `json:"events,omitempty"`
	Supported   *bool                            `json:"supported,omitempty"`
	Available   *bool                            `json:"available,omitempty"`
	Messages    *[]plugin.VoiceTranscriptMessage `json:"messages,omitempty"`
}
type Source struct {
	Supported, Available bool
	Prepare              func(context.Context) (plugin.VoiceSession, error)
}
type SourceFunc func(context.Context, string) (Source, error)
type Manager struct {
	root           string
	source         SourceFunc
	ctx            context.Context
	mu             sync.Mutex
	closing        bool
	calls, retired map[string]*call
	histories      map[string]*history
}
type call struct {
	threadID, requestID, device string
	ctx                         context.Context
	cancel                      context.CancelFunc
	mu                          sync.Mutex
	preparation                 chan struct{}
	session                     plugin.VoiceSession
	history                     *history
	prepareErr, persistenceErr  error
	unsubscribe                 func()
	eventsClosed                bool
	workers                     sync.WaitGroup
	stopOnce                    sync.Once
	stopped                     chan struct{}
	stopErr                     error
}

func New(ctx context.Context, root string, source SourceFunc) *Manager {
	return &Manager{ctx: ctx, root: root, source: source, histories: map[string]*history{}, calls: map[string]*call{}, retired: map[string]*call{}}
}
func (m *Manager) history(threadID string) (*history, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if h := m.histories[threadID]; h != nil {
		return h, nil
	}
	h, err := loadHistory(m.root, threadID)
	if err != nil {
		return nil, err
	}
	m.histories[threadID] = h
	return h, nil
}
func (m *Manager) Command(ctx context.Context, r Request) (Result, error) {
	empty := Result{}
	device := model.ClientDeviceID(ctx)
	if r.Request.Action == "stop" {
		m.mu.Lock()
		c := m.calls[device]
		m.mu.Unlock()
		if c != nil && c.threadID == r.ThreadID {
			c.mu.Lock()
			matches := c.requestID == r.Request.OwnershipID && (c.requestID == r.Request.SessionID || c.session != nil && c.session.ID() == r.Request.SessionID)
			c.mu.Unlock()
			if matches {
				return empty, m.stop(ctx, c)
			}
		}
		return empty, nil
	}
	source, err := m.source(ctx, r.ThreadID)
	if err != nil {
		return empty, err
	}
	if r.Request.Action == "history" {
		h, e := m.history(r.ThreadID)
		if e != nil {
			return empty, e
		}
		messages := h.snapshot()
		return Result{Supported: &source.Supported, Available: &source.Available, Messages: &messages}, nil
	}
	if r.Request.Action == "prepare" {
		return m.prepare(ctx, r, source)
	}
	m.mu.Lock()
	candidates := []*call{m.calls[device], m.retired[device]}
	active := m.calls[device]
	m.mu.Unlock()
	var selected *call
	for _, c := range candidates {
		if c == nil || c.threadID != r.ThreadID {
			continue
		}
		c.mu.Lock()
		matches := c.requestID == r.Request.OwnershipID && c.session != nil && c.session.ID() == r.Request.SessionID
		c.mu.Unlock()
		if matches {
			selected = c
			break
		}
	}
	if selected == nil {
		return empty, errors.New("语音分支已结束，请重新开始")
	}
	selected.mu.Lock()
	session, persistErr := selected.session, selected.persistenceErr
	selected.mu.Unlock()
	if persistErr != nil {
		return empty, fmt.Errorf("语音记录保存失败: %w", persistErr)
	}
	if r.Request.Action == "poll" {
		events, e := session.Poll(r.Request.After)
		if events == nil {
			events = []plugin.VoiceEvent{}
		}
		return Result{Events: &events}, e
	}
	if r.Request.Action == "heartbeat" {
		if selected != active {
			return empty, errors.New("语音分支已失效")
		}
		session.Heartbeat()
		return empty, nil
	}
	if r.Request.Action != "start" {
		return empty, errors.New("unknown thread voice action")
	}
	if selected != active || !source.Available {
		return empty, errors.New("语音分支已失效")
	}
	startCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	detach := context.AfterFunc(selected.ctx, cancel)
	defer detach()
	sdp, e := session.Start(startCtx, r.Request.SDP)
	return Result{SDP: sdp}, e
}
func (m *Manager) prepare(ctx context.Context, r Request, source Source) (Result, error) {
	empty := Result{}
	device := model.ClientDeviceID(ctx)
	if err := ctx.Err(); err != nil {
		return empty, err
	}
	if !source.Available || source.Prepare == nil {
		return empty, errors.New("此任务当前不支持只读语音讨论")
	}
	m.mu.Lock()
	if m.closing || m.ctx.Err() != nil || ctx.Err() != nil {
		m.mu.Unlock()
		return empty, errors.New("voice owner is closing")
	}
	if m.calls[device] != nil {
		m.mu.Unlock()
		return empty, errors.New("请先结束正在进行的语音讨论")
	}
	lifetime, cancel := context.WithCancel(m.ctx)
	c := &call{threadID: r.ThreadID, requestID: r.Request.RequestID, device: device, ctx: lifetime, cancel: cancel, preparation: make(chan struct{}), stopped: make(chan struct{})}
	m.calls[device] = c
	m.mu.Unlock()
	// Request cancellation applies while preparing; a completed HTTP request does
	// not own the lifetime of the already accepted native voice discussion.
	detach := context.AfterFunc(ctx, cancel)
	h, err := m.history(r.ThreadID)
	var session plugin.VoiceSession
	if err == nil {
		err = lifetime.Err()
	}
	if err == nil {
		session, err = source.Prepare(lifetime)
	}
	if err == nil && session == nil {
		err = errors.New("voice preparation returned no session")
	}
	c.mu.Lock()
	c.history = h
	c.session = session
	c.prepareErr = err
	c.mu.Unlock()
	close(c.preparation)
	detach()
	if err == nil {
		err = lifetime.Err()
	}
	if err != nil {
		return empty, errors.Join(err, m.stop(context.Background(), c))
	}
	unsubscribe := session.OnEvent(func(event plugin.VoiceEvent) {
		c.mu.Lock()
		if c.eventsClosed {
			c.mu.Unlock()
			return
		}
		message := plugin.VoiceTranscript(event)
		if message != nil {
			if e := h.update(*message); e != nil {
				c.persistenceErr = e
				c.cancel()
			}
		}
		save := message != nil && message.Complete || event.Type == "closed"
		if save {
			c.workers.Add(1)
		}
		c.mu.Unlock()
		if save {
			go func() {
				defer c.workers.Done()
				if e := h.save(context.Background()); e != nil {
					c.mu.Lock()
					c.persistenceErr = e
					c.mu.Unlock()
					c.cancel()
					go func() { _ = m.stop(context.Background(), c) }()
				}
			}()
		}
		if event.Type == "closed" {
			go func() { _ = m.stop(context.Background(), c) }()
		}
	})
	c.mu.Lock()
	if c.eventsClosed {
		c.mu.Unlock()
		unsubscribe()
		return empty, errors.Join(errors.New("voice discussion stopped during preparation"), m.stop(context.Background(), c))
	}
	c.unsubscribe = unsubscribe
	c.mu.Unlock()
	if session.Closed() {
		return empty, errors.Join(errors.New("语音分支在准备时已关闭"), m.stop(context.Background(), c))
	}
	if err = lifetime.Err(); err != nil {
		return empty, errors.Join(err, m.stop(context.Background(), c))
	}
	go func() { <-lifetime.Done(); _ = m.stop(context.Background(), c) }()
	return Result{SessionID: session.ID(), OwnershipID: c.requestID}, nil
}
func (m *Manager) stop(ctx context.Context, c *call) error {
	c.stopOnce.Do(func() {
		c.cancel()
		go func() {
			<-c.preparation
			c.mu.Lock()
			session, h := c.session, c.history
			c.mu.Unlock()
			var err error
			if session != nil {
				err = session.Stop(context.Background())
			}
			c.mu.Lock()
			c.eventsClosed = true
			unsubscribe := c.unsubscribe
			c.mu.Unlock()
			if unsubscribe != nil {
				unsubscribe()
			}
			c.workers.Wait()
			if h != nil {
				id := ""
				if session != nil {
					id = session.ID()
				}
				h.finish(id)
				err = errors.Join(err, h.save(context.Background()))
			}
			c.mu.Lock()
			err = errors.Join(err, c.persistenceErr)
			c.stopErr = err
			c.mu.Unlock()
			m.mu.Lock()
			if m.calls[c.device] == c && err == nil {
				delete(m.calls, c.device)
				m.retired[c.device] = c
			}
			m.mu.Unlock()
			close(c.stopped)
		}()
	})
	select {
	case <-c.stopped:
		c.mu.Lock()
		err := c.stopErr
		c.mu.Unlock()
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (m *Manager) End(ctx context.Context, id string) error {
	m.mu.Lock()
	var calls []*call
	for _, c := range m.calls {
		if c.threadID == id {
			calls = append(calls, c)
		}
	}
	m.mu.Unlock()
	var failures []error
	for _, c := range calls {
		failures = append(failures, m.stop(ctx, c))
	}
	return errors.Join(failures...)
}
func (m *Manager) Close(ctx context.Context) error {
	m.mu.Lock()
	m.closing = true
	var calls []*call
	for _, c := range m.calls {
		calls = append(calls, c)
	}
	m.mu.Unlock()
	var failures []error
	for _, c := range calls {
		failures = append(failures, m.stop(ctx, c))
	}
	m.mu.Lock()
	histories := make([]*history, 0, len(m.histories))
	for _, h := range m.histories {
		histories = append(histories, h)
	}
	m.mu.Unlock()
	for _, h := range histories {
		failures = append(failures, h.save(ctx))
	}
	return errors.Join(failures...)
}
func (m *Manager) RevokeDevice(ctx context.Context, device string) error {
	m.mu.Lock()
	c := m.calls[device]
	delete(m.retired, device)
	m.mu.Unlock()
	if c != nil {
		return m.stop(ctx, c)
	}
	return nil
}
func (m *Manager) Active() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.calls) > 0
}
func (m *Manager) Remove(ctx context.Context, id string) error {
	if err := m.End(ctx, id); err != nil {
		return err
	}
	h, err := m.history(id)
	if err != nil {
		return err
	}
	if err = h.remove(); err != nil {
		return err
	}
	m.mu.Lock()
	delete(m.histories, id)
	for device, c := range m.retired {
		if c.threadID == id {
			delete(m.retired, device)
		}
	}
	m.mu.Unlock()
	return nil
}
func (m *Manager) Clear(ctx context.Context) error {
	if err := m.Close(ctx); err != nil {
		return err
	}
	if err := os.RemoveAll(m.root); err != nil {
		return err
	}
	m.mu.Lock()
	m.histories = map[string]*history{}
	m.retired = map[string]*call{}
	m.closing = false
	m.mu.Unlock()
	return nil
}

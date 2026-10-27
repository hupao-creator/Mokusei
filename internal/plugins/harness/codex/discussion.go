package codex

import (
	"context"
	"errors"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"strings"
	"sync"
)

type discussionRun struct {
	id                       string
	ready, done              chan struct{}
	readyOnce, doneOnce      sync.Once
	answer, failure, outcome string
	voice                    *plugin.VoiceDelegation
}
type Discussion struct {
	mu       sync.Mutex
	adapter  *Adapter
	native   *NativeSession
	options  NativeOptions
	lifetime context.Context
	cancel   context.CancelFunc
	voice    *VoiceSession
	closed   bool
	active   *discussionRun
}

func (a *Adapter) PrepareDiscussion(ctx context.Context, r plugin.DiscussionRequest) (plugin.Discussion, error) {
	state, e := DecodeState(rawMap(r.Source.SessionState))
	if e != nil {
		return nil, e
	}
	source := str(state["primarySessionId"])
	if source == "" {
		return nil, errors.New("请先在此任务中完成一次对话，再开始语音讨论")
	}
	cwd := r.Source.Cwd
	if r.Source.Worktree != nil {
		cwd = r.Source.Worktree.Cwd
	}
	settings := rawMap(r.Source.Settings)
	settings["approvalPolicy"] = "never"
	settings["approvalsReviewer"] = "user"
	settings["sandbox"] = "read-only"
	settings["ephemeral"] = true
	delete(settings, "sandboxPolicy")
	s, e := a.server(ctx, cwd, str(settings["executablePath"]), "discussion", "")
	if e != nil {
		return nil, e
	}
	n := NewNativeSession(s)
	o := NativeOptions{Cwd: cwd, ForkSessionID: source, Settings: settings, ToolMode: "exclusive", Tools: r.Tools, Instructions: composeInstructions(nil, str(state["nativeHistorySeed"])) + "\n\n" + r.Instructions}
	id, e := n.Prepare(ctx, o)
	if e != nil {
		n.Close()
		return nil, e
	}
	if id == source {
		n.Close()
		return nil, errors.New("讨论未创建独立会话")
	}
	o.ForkSessionID = ""
	o.SessionID = id
	lifetime, cancel := context.WithCancel(ctx)
	d := &Discussion{adapter: a, native: n, options: o, lifetime: lifetime, cancel: cancel}
	go func() { <-lifetime.Done(); _ = d.Close() }()
	return d, nil
}
func (d *Discussion) newRun(id string) *discussionRun {
	run := &discussionRun{id: id, ready: make(chan struct{}), done: make(chan struct{})}
	d.active = run
	return run
}
func (d *Discussion) Ask(ctx context.Context, question string) (string, error) {
	if strings.TrimSpace(question) == "" {
		return "", errors.New("discussion question is empty")
	}
	d.mu.Lock()
	if d.closed {
		d.mu.Unlock()
		return "", errors.New("Codex discussion closed")
	}
	run := d.active
	created := run == nil
	if created {
		run = d.newRun(uid())
	}
	d.mu.Unlock()
	input := []any{Map{"type": "text", "text": question, "text_elements": []any{}}}
	var err error
	if created {
		err = d.native.Start(ctx, d.options, run.id, input, d.receive)
		run.readyOnce.Do(func() { close(run.ready) })
	} else {
		select {
		case <-run.ready:
			err = d.native.Steer(ctx, input)
		case <-ctx.Done():
			err = ctx.Err()
		case <-d.lifetime.Done():
			err = d.lifetime.Err()
		}
	}
	if err != nil {
		d.mu.Lock()
		run.failure = err.Error()
		run.outcome = "failed"
		run.doneOnce.Do(func() { close(run.done) })
		if d.active == run {
			d.active = nil
		}
		d.mu.Unlock()
		return "", err
	}
	select {
	case <-ctx.Done():
		_ = d.Close()
		return "", ctx.Err()
	case <-d.lifetime.Done():
		return "", d.lifetime.Err()
	case <-run.done:
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if run.outcome != "completed" {
		return "", errors.New(first(run.failure, "讨论未完成："+run.outcome))
	}
	return first(strings.TrimSpace(run.answer), "讨论没有返回可播报的公开答复。"), nil
}
func (d *Discussion) receive(event Map) {
	d.mu.Lock()
	run := d.active
	if run == nil {
		d.mu.Unlock()
		return
	}
	var speech *plugin.VoiceSpeech
	voice := d.voice
	switch event["type"] {
	case "public-final":
		run.answer = str(event["text"])
	case "error":
		run.failure = str(event["message"])
	case "interaction-opened":
		run.failure = "只读讨论不能请求执行或授权，请回到原任务处理"
		run.outcome = "failed"
		run.doneOnce.Do(func() { close(run.done) })
		go d.Close()
	case "done":
		run.outcome = str(event["outcome"])
		run.doneOnce.Do(func() { close(run.done) })
		d.active = nil
		if run.voice != nil && run.outcome == "completed" && voice != nil {
			speech = &plugin.VoiceSpeech{DeliveryID: run.voice.ID, Generation: run.voice.Generation, Text: run.answer}
		}
	}
	d.mu.Unlock()
	if speech != nil {
		go func() { _ = voice.Speak(d.lifetime, *speech) }()
	}
}
func (d *Discussion) Close() error {
	d.mu.Lock()
	if d.closed {
		d.mu.Unlock()
		return nil
	}
	d.closed = true
	voice := d.voice
	run := d.active
	if run != nil {
		run.outcome = "interrupted"
		run.doneOnce.Do(func() { close(run.done) })
		run.readyOnce.Do(func() { close(run.ready) })
	}
	d.mu.Unlock()
	d.cancel()
	if voice != nil {
		voice.Close()
	}
	return d.native.Close()
}
func (d *Discussion) PrepareNativeVoice(ctx context.Context, entries []plugin.ContextEntry) (plugin.VoiceSession, error) {
	nativeAccount, e := d.adapter.usesNativeAccount(ctx, d.native.server, d.options.Cwd)
	if e != nil {
		return nil, e
	}
	if !nativeAccount {
		return nil, errors.New("此 Codex 讨论无法直接使用原生 ChatGPT 语音；不会使用转发层")
	}
	d.mu.Lock()
	if d.voice != nil || d.closed {
		d.mu.Unlock()
		return nil, errors.New("讨论语音已准备或讨论已关闭")
	}
	v := newVoiceSession(d.lifetime, d.native, d.options.Instructions+"\nDelegate every substantive question to native Codex. Never advance the source task.", func() error { return nil })
	d.voice = v
	d.mu.Unlock()
	d.native.mu.Lock()
	d.native.nativeAdmit = func(turn string) (string, error) {
		request, e := v.claimRequest()
		if e != nil {
			return "", e
		}
		d.mu.Lock()
		defer d.mu.Unlock()
		if d.closed || d.active != nil {
			return "", errors.New("discussion already has an active execution")
		}
		run := d.newRun(uid())
		run.voice = &request
		run.readyOnce.Do(func() { close(run.ready) })
		return run.id, nil
	}
	d.native.emit = d.receive
	d.native.mu.Unlock()
	v.mu.Lock()
	v.protocolFailure = func(error) { go d.Close() }
	v.onNativeInput = func(request plugin.VoiceDelegation, turn string) {
		d.mu.Lock()
		run := d.active
		if run != nil {
			run.voice = &request
		}
		d.mu.Unlock()
		if run == nil {
			v.fail(errors.New("讨论补充消息失去执行"))
			return
		}
		if e := v.publishRequest(d.lifetime, request, run.id); e != nil {
			v.fail(e)
		}
	}
	v.mu.Unlock()
	if e = v.SyncContext(ctx, entries); e != nil {
		v.Close()
		return nil, e
	}
	return v, nil
}

var _ plugin.DiscussionPreparer = (*Adapter)(nil)
var _ plugin.NativeVoiceCapability = (*Discussion)(nil)

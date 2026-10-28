package codex

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type NativeOptions struct {
	Cwd, SessionID, ForkSessionID, Instructions, ToolMode string
	RequireExplicitSettings                               bool
	Settings                                              Map
	Tools                                                 []plugin.ToolBinding
	WritableRoots                                         []string
}
type nativePending struct {
	id                  any
	method              string
	params, interaction Map
	timer               *time.Timer
}
type NativeSession struct {
	mu                          sync.Mutex
	notificationMu              sync.Mutex
	server                      *AppServer
	id, turnID, executionID     string
	settings                    Map
	reasoning, finals, outputs  map[string]string
	finalOrder                  []string
	seenUsage                   map[string]bool
	pending                     map[string]*nativePending
	emit                        func(Map)
	activity                    func(Map)
	realtime                    func(string, Map)
	nativeAdmit                 func(string) (string, error)
	nativeConfigurationRejected func(error)
	nativeAdmissionCancelled    func(string)
	terminal                    bool
	bridge                      *ToolBridge
	completed                   chan struct{}
	failure                     string
	closed                      bool
	closeOnce                   sync.Once
	closeErr                    error
	background                  map[string]Map
	tombstones                  map[string]bool
	refreshMu                   sync.Mutex
	toolContext                 context.Context
	toolCancel                  context.CancelFunc
	toolCalls                   map[string]bool
	toolWorkers                 *sync.WaitGroup
	nativeBacklog               []Map
	nativeBacklogBytes          int
	retiredTurns                map[string]bool
	retryTimer                  *time.Timer
	retryCount                  int
	retryGeneration             uint64
}

func NewNativeSession(s *AppServer) *NativeSession {
	return newNativeSession(s, nil)
}
func newNativeSession(s *AppServer, activity func(*NativeSession, Map)) *NativeSession {
	n := &NativeSession{server: s, pending: map[string]*nativePending{}, terminal: true, background: map[string]Map{}, tombstones: map[string]bool{}, retiredTurns: map[string]bool{}}
	if activity != nil {
		n.activity = func(e Map) { activity(n, e) }
	}
	s.SetHandler(func(method string, params Map, id any) {
		n.notificationMu.Lock()
		defer n.notificationMu.Unlock()
		n.mu.Lock()
		closed := n.closed
		n.mu.Unlock()
		if !closed {
			n.notification(method, params, id)
		}
	}, n.failed)
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-s.done:
				return
			case <-ticker.C:
				n.mu.Lock()
				has := len(n.background) > 0
				n.mu.Unlock()
				if has {
					n.refreshBackground()
				}
			}
		}
	}()
	return n
}
func (n *NativeSession) Prepare(ctx context.Context, o NativeOptions) (string, error) {
	if err := n.validateSettings(ctx, &o); err != nil {
		return "", err
	}
	return n.prepare(ctx, o)
}

// prepare receives validated native wire settings. Keep the original thinking
// choice validation separate from its conversion to native effort settings.
func (n *NativeSession) prepare(ctx context.Context, o NativeOptions) (string, error) {
	n.mu.Lock()
	loaded := n.id
	if n.closed {
		n.mu.Unlock()
		return "", errors.New("Codex session closed")
	}
	n.mu.Unlock()
	if loaded != "" && o.ForkSessionID == "" && o.SessionID == loaded {
		return loaded, nil
	}
	config := Map{"tools": Map{"update_plan": Map{"enabled": true}}}
	if o.ToolMode == "exclusive" {
		var err error
		config, err = n.exclusiveConfig(ctx, o.Cwd)
		if err != nil {
			return "", err
		}
	}
	if e := o.Settings["effort"]; e != nil {
		config["model_reasoning_effort"] = e
	}
	if e := o.Settings["summary"]; e != nil {
		config["model_reasoning_summary"] = e
	}
	var bridge *ToolBridge
	var err error
	if len(o.Tools) > 0 {
		bridge, err = NewToolBridge(o.Tools, n.executeTool)
		if err != nil {
			return "", err
		}
		servers := obj(config["mcp_servers"])
		servers["mokusei_injected"] = bridge.Configuration()
		config["mcp_servers"] = servers
	}
	cleanup := func() {
		if bridge != nil {
			_ = bridge.Close()
		}
	}
	if o.Settings["approvalsReviewer"] == "auto_review" {
		supported, e := n.supportsAutoReview(ctx, o.Cwd)
		if e != nil || !supported {
			cleanup()
			return "", errors.New("Codex approve-for-me 自动审批不可用")
		}
	}
	if o.Settings["approvalsReviewer"] != nil && o.Settings["sandbox"] == "workspace-write" {
		config["sandbox_workspace_write"] = Map{"writable_roots": []any{}, "network_access": false, "exclude_tmpdir_env_var": false, "exclude_slash_tmp": false}
	}
	if len(o.WritableRoots) > 0 {
		config["sandbox_workspace_write"] = Map{"writable_roots": o.WritableRoots, "network_access": false, "exclude_tmpdir_env_var": false, "exclude_slash_tmp": false}
		o.Instructions += "\n\nThis Codex turn runs in a Mokusei-managed detached linked worktree. Standard git add and git commit are available in the current worktree. Keep HEAD detached, do not create or switch branches, and do not operate on the base checkout, another worktree, or shared refs. Return the commit SHA; integration into the base branch is owned by the caller."
	}
	base := present(o.Settings, "model", "serviceTier", "approvalsReviewer", "personality")
	base["cwd"] = o.Cwd
	base["approvalPolicy"] = first(str(o.Settings["approvalPolicy"]), "on-request")
	base["sandbox"] = first(str(o.Settings["sandbox"]), "workspace-write")
	switch obj(o.Settings["sandboxPolicy"])["type"] {
	case "readOnly":
		base["sandbox"] = "read-only"
	case "workspaceWrite":
		base["sandbox"] = "workspace-write"
	case "dangerFullAccess", "externalSandbox":
		base["sandbox"] = "danger-full-access"
	}
	base["config"] = config
	if o.Instructions != "" || o.ForkSessionID != "" {
		base["developerInstructions"] = o.Instructions
	}
	if str(o.Settings["model"]) != "" {
		base["allowProviderModelFallback"] = false
	}
	method := "thread/start"
	if o.ForkSessionID != "" {
		method = "thread/fork"
		base["threadId"] = o.ForkSessionID
		base["excludeTurns"] = true
		base["ephemeral"] = o.Settings["ephemeral"] == true
	} else if o.SessionID != "" {
		method = "thread/resume"
		base["threadId"] = o.SessionID
	} else {
		base["experimentalRawEvents"] = true
		base["ephemeral"] = o.Settings["ephemeral"] == true
		base["serviceName"] = "mokusei_desktop"
	}
	r, err := n.server.Call(ctx, method, base)
	if err != nil {
		cleanup()
		return "", err
	}
	id := str(obj(r["thread"])["id"])
	if id == "" {
		cleanup()
		return "", errors.New("Codex app-server 未返回 thread ID")
	}
	for _, k := range []string{"approvalsReviewer", "approvalPolicy"} {
		if o.Settings["approvalsReviewer"] != nil && r[k] != o.Settings[k] {
			cleanup()
			return "", fmt.Errorf("Codex 未应用 %s", k)
		}
	}
	if o.Settings["approvalsReviewer"] != nil && o.Settings["sandbox"] != nil {
		expected := map[string]string{"workspace-write": "workspaceWrite", "read-only": "readOnly", "danger-full-access": "dangerFullAccess"}[str(o.Settings["sandbox"])]
		if obj(r["sandbox"])["type"] != expected {
			cleanup()
			return "", errors.New("Codex runtime 未确认请求的权限配置；拒绝启动任务")
		}
	}
	if requested, explicit := o.Settings["serviceTier"]; explicit {
		tier, reported := r["serviceTier"]
		if tier == nil {
			tier = "default"
		}
		if !reported || tier != requested {
			cleanup()
			return "", errors.New("Codex runtime 未确认请求的服务层级；拒绝启动任务")
		}
	}
	if o.Settings["model"] != nil && o.Settings["serviceTier"] != nil && o.Settings["permissionMode"] != nil {
		if o.Settings["effort"] != nil && r["reasoningEffort"] != o.Settings["effort"] {
			cleanup()
			return "", errors.New("Codex runtime 未确认固定的推理强度或服务层级")
		}
	}
	n.mu.Lock()
	n.id = id
	n.settings = clone(o.Settings)
	if r["model"] != nil {
		n.settings["model"] = r["model"]
	}
	if tier, ok := r["serviceTier"]; ok {
		n.settings["serviceTier"] = tier
	}
	oldBridge := n.bridge
	n.bridge = bridge
	n.mu.Unlock()
	if bridge != nil {
		bridge.Bind(id)
	}
	if oldBridge != nil {
		_ = oldBridge.Close()
	}
	return id, nil
}
func (n *NativeSession) Start(ctx context.Context, o NativeOptions, executionID string, input []any, emit func(Map)) error {
	if err := n.validateSettings(ctx, &o); err != nil {
		return err
	}
	id, err := n.prepare(ctx, o)
	if err != nil {
		return err
	}
	n.mu.Lock()
	if !n.terminal {
		n.mu.Unlock()
		return errors.New("Codex Primary Session 仍在运行")
	}
	n.executionID = executionID
	n.turnID = ""
	n.terminal = false
	n.failure = ""
	n.reasoning = map[string]string{}
	n.finals = map[string]string{}
	n.finalOrder = nil
	n.outputs = map[string]string{}
	n.seenUsage = map[string]bool{}
	n.completed = make(chan struct{})
	n.toolContext, n.toolCancel = context.WithCancel(context.Background())
	n.toolCalls = map[string]bool{}
	n.toolWorkers = &sync.WaitGroup{}
	n.emit = emit
	settings := clone(n.settings)
	n.mu.Unlock()
	n.publish(Map{"type": "session", "sessionId": id})
	if settings["model"] != nil {
		n.publish(Map{"type": "runtime-model", "model": settings["model"]})
	}
	if tier, ok := settings["serviceTier"]; ok {
		n.publish(Map{"type": "runtime-service-tier", "serviceTier": tier})
	}
	n.publish(Map{"type": "status", "label": "正在连接 Codex"})
	params := turnSettings(o.Settings, o.WritableRoots)
	params["threadId"] = id
	params["clientUserMessageId"] = executionID
	params["input"] = input
	params["cwd"] = o.Cwd
	r, err := n.server.Call(ctx, "turn/start", params)
	if err != nil {
		n.finish(Map{"status": "failed", "error": Map{"message": err.Error()}})
		_ = n.server.Close()
		return err
	}
	turnID := str(obj(r["turn"])["id"])
	if turnID == "" {
		err = errors.New("Codex app-server 未返回 turn ID")
		n.finish(Map{"status": "failed", "error": Map{"message": err.Error()}})
		return err
	}
	n.mu.Lock()
	if n.turnID != "" && n.turnID != turnID {
		n.mu.Unlock()
		_ = n.server.Close()
		return errors.New("Codex turn identity mismatch")
	}
	n.turnID = turnID
	failure := n.failure
	terminal := n.terminal
	n.mu.Unlock()
	if terminal && failure != "" {
		_, _ = n.server.Call(context.Background(), "turn/interrupt", Map{"threadId": id, "turnId": turnID})
		_ = n.server.Close()
		return errors.New(failure)
	}
	return nil
}
func (n *NativeSession) publish(e Map) {
	n.mu.Lock()
	emit := n.emit
	executionID := n.executionID
	n.mu.Unlock()
	e = clone(e)
	e["_nativeExecutionId"] = executionID
	if emit != nil {
		emit(e)
	}
}

var errSteerTargetEnded = errors.New("Codex steer target ended before admission")

func (n *NativeSession) Steer(ctx context.Context, input []any) error {
	// Normal task admission must reconcile acknowledgement even after cancellation.
	return n.steer(ctx, context.WithoutCancel(ctx), input)
}

// finish marks native terminal before publishing the durable done event. Wait
// for that publication without holding either the handle or native state lock.
func (n *NativeSession) waitForSettlement(ctx context.Context) (bool, error) {
	n.mu.Lock()
	terminal, done := n.terminal, n.completed
	n.mu.Unlock()
	if !terminal || done == nil {
		return terminal, nil
	}
	select {
	case <-done:
		return true, nil
	case <-ctx.Done():
		return true, ctx.Err()
	}
}

// Isolated completions pass the same cancellable context for both lifetimes.
func (n *NativeSession) steer(ctx, requestParent context.Context, input []any) error {
	n.mu.Lock()
	id, turn, terminal, done := n.id, n.turnID, n.terminal, n.completed
	n.mu.Unlock()
	if terminal {
		return errSteerTargetEnded
	}
	if turn == "" {
		return errors.New("Codex 当前没有可续发的 turn")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	requestCtx, cancel := context.WithTimeout(requestParent, 30*time.Second)
	defer cancel()
	_, err := n.server.Call(requestCtx, "turn/steer", Map{"threadId": id, "expectedTurnId": turn, "input": input})
	if err == nil {
		return nil
	}
	var rejection *RPCError
	if !errors.As(err, &rejection) || rejection.Code != -32600 || strings.ToLower(strings.TrimSpace(rejection.Message)) != "no active turn to steer" {
		return err
	}
	// RPC replies bypass the notification queue. An explicit rejection can
	// precede local terminal publication by arbitrarily many queued events;
	// polling/reissuing steer on a fixed schedule cannot establish settlement.
	// Only the captured completion, followed by the handle's durable check,
	// permits Core to reserve one successor. Timeout/cancellation keep the error.
	select {
	case <-done:
		return errSteerTargetEnded
	case <-ctx.Done():
		return errors.Join(err, ctx.Err())
	case <-requestCtx.Done():
		return errors.Join(err, requestCtx.Err())
	}
}

// Interrupt stops both the foreground turn and its native background terminals.
// An RPC acknowledgement alone does not prove that either owner has stopped.
func (n *NativeSession) Interrupt(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	n.mu.Lock()
	id, turn, terminal, closed, done := n.id, n.turnID, n.terminal, n.closed, n.completed
	n.mu.Unlock()
	if closed {
		return n.Close()
	}
	if !terminal {
		if turn == "" {
			return errors.New("Codex turn admission is pending")
		}
		if _, err := n.server.Call(ctx, "turn/interrupt", Map{"threadId": id, "turnId": turn}); err != nil {
			return err
		}
	}
	if done != nil {
		select {
		case <-done:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	if id == "" {
		return nil
	}
	if err := n.refreshBackgroundContext(ctx); err != nil {
		return err
	}
	n.mu.Lock()
	has := len(n.background) > 0
	n.mu.Unlock()
	if has {
		if _, err := n.server.Call(ctx, "thread/backgroundTerminals/clean", Map{"threadId": id}); err != nil {
			return fmt.Errorf("stop Codex background terminals: %w", err)
		}
	}
	for {
		if err := n.refreshBackgroundContext(ctx); err != nil {
			return err
		}
		n.mu.Lock()
		has = len(n.background) > 0
		n.mu.Unlock()
		if !has {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("Codex background terminals have not stopped: %w", ctx.Err())
		case <-time.After(25 * time.Millisecond):
		}
	}
}
func (n *NativeSession) Respond(ctx context.Context, id string, response Map) error {
	return n.RespondExecution(ctx, "", id, response)
}
func (n *NativeSession) RespondExecution(ctx context.Context, executionID, id string, response Map) error {
	n.mu.Lock()
	if executionID != "" && n.executionID != executionID {
		n.mu.Unlock()
		return errors.New("Codex interaction execution changed")
	}
	p := n.pending[id]
	n.mu.Unlock()
	if p == nil {
		return errors.New("Codex interaction no longer pending")
	}
	result, resolution, err := EncodeInteractionResponse(p.method, p.params, p.interaction, response)
	if err != nil {
		return err
	}
	n.mu.Lock()
	if n.pending[id] != p || executionID != "" && n.executionID != executionID {
		n.mu.Unlock()
		return errors.New("Codex interaction no longer pending")
	}
	delete(n.pending, id)
	if p.timer != nil {
		p.timer.Stop()
	}
	n.mu.Unlock()
	if err = n.server.Reply(p.id, result, nil); err != nil {
		return err
	}

	n.publish(Map{"type": "interaction-closed", "interactionId": id, "resolution": resolution})
	return nil
}
func (n *NativeSession) notification(method string, p Map, wireID any) {
	if n.routeNativePending(method, p, wireID) {
		return
	}
	if wireID != nil {
		n.request(method, p, wireID)
		return
	}
	n.mu.Lock()
	id, turn, terminal, rt := n.id, n.turnID, n.terminal, n.realtime
	n.mu.Unlock()
	if rt != nil && (strings.HasPrefix(method, "thread/realtime/") || method == "turn/started") {
		rt(method, p)
	}
	if strings.HasPrefix(method, "thread/realtime/") {
		return
	}
	if str(p["threadId"]) != id {
		return
	}
	// Background commands can outlive their retired foreground turn. Preserve
	// their completion, while rejecting all late foreground work for that turn.
	if method == "item/completed" && n.completeBackground(obj(p["item"])) {
		return
	}
	nativeTurn := first(str(p["turnId"]), str(obj(p["turn"])["id"]))
	n.mu.Lock()
	retired := n.retiredTurns[nativeTurn]
	n.mu.Unlock()
	if retired {
		return
	}
	if terminal && method == "turn/started" && nativeTurn != "" {
		if e := n.admitNative(nativeTurn); e != nil {
			if e == errNativeVoiceAdmissionCancelled {
				n.mu.Lock()
				n.retiredTurns[nativeTurn] = true
				cancel := n.nativeAdmissionCancelled
				n.mu.Unlock()
				if cancel != nil {
					cancel(nativeTurn)
					return
				}
			}
			if e == plugin.ErrMokuConfigurationPending {
				n.mu.Lock()
				callback := n.nativeConfigurationRejected
				if callback != nil {
					n.retiredTurns[nativeTurn] = true
					n.nativeAdmit = nil
				}
				n.mu.Unlock()
				if callback != nil {
					// Core rejected before any tool/execution was admitted. Drain
					// the original process before handing its exact input back;
					// generic failures never enter this recovery path.
					go func() { callback(n.Close()) }()
					return
				}
			}
			n.protocolFailure(e.Error())
			return
		}
		terminal = false
		turn = nativeTurn
		n.drainNativePending(nativeTurn)
	}
	if method == "turn/started" {
		n.mu.Lock()
		if !n.terminal && n.turnID == "" {
			n.turnID = nativeTurn
		}
		n.mu.Unlock()
	}
	if method == "thread/status/changed" {
		if n.activity != nil {
			n.activity(Map{"type": "status", "threadId": id, "status": str(obj(p["status"])["type"]), "at": now()})
		}
		return
	}
	if terminal {
		return
	}
	if turn != "" && nativeTurn != "" && turn != nativeTurn {
		return
	}
	if nativeProgress(method, p) {
		n.mu.Lock()
		n.clearRetryLocked()
		n.mu.Unlock()
	}
	if item := obj(p["item"]); item["type"] == "mcpToolCall" && item["server"] == "mokusei_injected" {
		item = clone(item)
		item["type"] = "dynamicToolCall"
		p = clone(p)
		p["item"] = item
	}
	if item := obj(p["item"]); (method == "item/started" || method == "item/completed") && item["type"] == "userMessage" && rt != nil {
		texts := []string{}
		for _, part := range arr(item["content"]) {
			texts = append(texts, str(obj(part)["text"]))
		}
		text := strings.Join(texts, "\n")
		if strings.Contains(text, "<realtime_delegation>") {
			rt("mokusei/voice/delegation", Map{"turnId": nativeTurn, "itemId": str(item["id"]), "text": text})
		}
	}
	if events := DecodeNotification(method, p); events != nil {
		for _, e := range events {
			n.publish(e)
		}
		return
	}
	switch method {
	case "thread/settings/updated":
		s := obj(p["threadSettings"])
		n.mu.Lock()
		for k, v := range s {
			n.settings[k] = v
		}
		n.mu.Unlock()
		if str(s["model"]) != "" {
			n.publish(Map{"type": "runtime-model", "model": s["model"]})
		}
		if tier, ok := s["serviceTier"]; ok {
			n.publish(Map{"type": "runtime-service-tier", "serviceTier": tier})
		}
	case "item/agentMessage/delta":
		item := str(p["itemId"])
		if !validMessageID(item) {
			n.protocolFailure("Codex app-server agentMessage ID 无效")
			return
		}
		delta := str(p["delta"])
		n.publish(Map{"type": "text-delta", "itemId": item, "delta": delta})
	case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
		n.mu.Lock()
		n.reasoning[str(p["itemId"])] += str(p["delta"])
		n.mu.Unlock()
		n.publish(Map{"type": "reasoning-delta", "delta": str(p["delta"])})
		n.publish(Map{"type": "status", "label": "正在分析"})
	case "item/started":
		i := obj(p["item"])
		if i["type"] == "agentMessage" {
			id := str(i["id"])
			if !validMessageID(id) {
				n.protocolFailure("Codex agentMessage ID 无效")
				return
			}
			n.publish(Map{"type": "text-delta", "itemId": id, "delta": ""})
		}
	case "item/commandExecution/outputDelta":
		id := str(p["itemId"])
		n.mu.Lock()
		n.outputs[id] = tail(n.outputs[id]+str(p["delta"]), 32*1024)
		detail := n.outputs[id]
		n.mu.Unlock()
		n.publish(Map{"type": "activity-update", "activityId": id, "detail": detail})
	case "item/completed":
		n.completedItem(obj(p["item"]))
	case "serverRequest/resolved":
		n.mu.Lock()
		for id, pending := range n.pending {
			if wireKey(pending.id) == wireKey(p["requestId"]) {
				delete(n.pending, id)
				if pending.timer != nil {
					pending.timer.Stop()
				}
				n.mu.Unlock()
				n.publish(Map{"type": "interaction-closed", "interactionId": id, "resolution": "已由 Codex 结束"})
				return
			}
		}
		n.mu.Unlock()
	case "rawResponse/completed":
		id := str(p["responseId"])
		n.mu.Lock()
		seen := n.seenUsage[id]
		n.seenUsage[id] = true
		model := n.settings["model"]
		n.mu.Unlock()
		if id != "" && !seen {
			n.publish(Map{"type": "generation-usage", "nativeSessionId": n.id, "generationId": id, "model": model, "usage": present(obj(p["usage"]), "inputTokens", "cachedInputTokens", "cacheWriteInputTokens", "outputTokens", "reasoningOutputTokens")})
		}
	case "model/rerouted":
		n.publish(Map{"type": "runtime-model", "model": str(p["toModel"])})
		n.publish(Map{"type": "warning", "message": "模型已切换到 " + str(p["toModel"])})
	case "error":
		message := first(str(obj(p["error"])["message"]), str(p["message"]))
		if p["willRetry"] == true {
			n.retrying(message)
		} else {
			n.mu.Lock()
			n.failure = message
			n.mu.Unlock()
			n.publish(Map{"type": "error", "message": message})
		}
	case "turn/completed":
		n.finish(obj(p["turn"]))
	}
}
func (n *NativeSession) completedItem(i Map) {
	id := str(i["id"])
	switch i["type"] {
	case "agentMessage":
		if !validMessageID(id) {
			n.protocolFailure("Codex agentMessage ID 无效")
			return
		}
		text := str(i["text"])
		n.mu.Lock()
		if _, ok := n.finals[id]; !ok {
			n.finalOrder = append(n.finalOrder, id)
		}
		n.finals[id] = text
		n.mu.Unlock()
		n.publish(Map{"type": "text-final", "itemId": id, "text": text})
	case "reasoning":
		parts := []string{}
		for _, v := range arr(i["summary"]) {
			if s, ok := v.(string); ok {
				parts = append(parts, s)
			}
		}
		if len(parts) == 0 {
			for _, v := range arr(i["content"]) {
				if s, ok := v.(string); ok {
					parts = append(parts, s)
				}
			}
		}
		text := strings.Join(parts, "\n")
		n.mu.Lock()
		streamed := n.reasoning[id]
		n.mu.Unlock()
		if strings.HasPrefix(text, streamed) && len(text) > len(streamed) {
			n.publish(Map{"type": "reasoning-delta", "delta": text[len(streamed):]})
		}
	case "contextCompaction":
		n.publish(Map{"type": "context-compacted"})
	default:
		if i["type"] == "exitedReviewMode" {
			n.publish(Map{"type": "review", "review": str(i["review"])})
		}
		if e := CompletedActivity(i); e != nil {
			n.publish(e)
		}
	}
}
func (n *NativeSession) finish(turn Map) {
	n.mu.Lock()
	if n.terminal {
		n.mu.Unlock()
		return
	}
	n.terminal = true
	n.clearRetryLocked()
	if n.retiredTurns == nil {
		n.retiredTurns = map[string]bool{}
	}
	if n.turnID != "" {
		n.retiredTurns[n.turnID] = true
	}
	if n.toolCancel != nil {
		n.toolCancel()
	}
	toolWorkers := n.toolWorkers
	status := str(turn["status"])
	failure := first(str(obj(turn["error"])["message"]), n.failure)
	pending := n.pending
	n.pending = map[string]*nativePending{}
	done := n.completed
	finals := cloneStrings(n.finals)
	order := append([]string{}, n.finalOrder...)
	n.mu.Unlock()
	// Terminal publication is the successor's admission boundary. Cancelled
	// tools must release their scoped capabilities before that boundary opens.
	if toolWorkers != nil {
		toolWorkers.Wait()
	}
	nativeFinals := []Map{}
	for _, v := range arr(turn["items"]) {
		i := obj(v)
		if i["type"] == "agentMessage" {
			if !validMessageID(str(i["id"])) {
				status = "failed"
				failure = "Codex app-server agentMessage ID 无效"
				nativeFinals = nil
				finals = map[string]string{}
				order = nil
				break
			}
			nativeFinals = append(nativeFinals, i)
		}
	}
	if len(nativeFinals) > 0 {
		order = nil
		for _, i := range nativeFinals {
			id := str(i["id"])
			order = append(order, id)
			finals[id] = str(i["text"])
		}
	}
	display := []string{}
	for _, id := range order {
		display = append(display, finals[id])
	}
	all := strings.Join(display, "\n\n")
	for j, id := range order {
		e := Map{"type": "text-final", "itemId": id, "text": finals[id]}
		if j == len(order)-1 {
			e["displayText"] = all
		}
		n.publish(e)
	}
	for id, p := range pending {
		if p.timer != nil {
			p.timer.Stop()
		}
		n.publish(Map{"type": "interaction-closed", "interactionId": id, "resolution": "已由 Codex 结束"})
	}
	outcome := "completed"
	if status == "interrupted" {
		outcome = status
	} else if status == "failed" || failure != "" {
		outcome = "failed"
	}
	if failure != "" {
		n.publish(Map{"type": "error", "message": failure})
	}
	if outcome == "completed" {
		speech := []string{}
		for _, i := range nativeFinals {
			if (i["phase"] == "final_answer" || i["phase"] == "final") && i["questions"] == nil {
				speech = append(speech, str(i["text"]))
			}
		}
		if len(speech) > 0 {
			n.publish(Map{"type": "public-final", "text": strings.Join(speech, "\n\n")})
		}
	}
	backgroundErr := n.refreshBackground()
	if n.activity != nil {
		n.activity(Map{"type": "status-cleared", "threadId": n.id, "at": now()})
	}
	n.publish(Map{"type": "done", "outcome": outcome, "backgroundUnknown": backgroundErr != nil})
	if done != nil {
		close(done)
	}

}
func cloneStrings(m map[string]string) map[string]string {
	r := map[string]string{}
	for k, v := range m {
		r[k] = v
	}
	return r
}
func (n *NativeSession) failed(e error) {
	n.finish(Map{"status": "failed", "error": Map{"message": e.Error()}})
	// A closed protocol channel can precede actual process exit. Retire durable
	// activities only after the owned process group has been joined.
	if n.Close() == nil {
		// Join any in-flight list publication before publishing retirement.
		n.refreshMu.Lock()
		if n.activity != nil {
			n.activity(Map{"type": "background-retired"})
		}
		n.refreshMu.Unlock()
	}
}
func (n *NativeSession) protocolFailure(message string) {
	n.mu.Lock()
	n.failure = message
	n.mu.Unlock()
	go func() {
		ctx, c := context.WithTimeout(context.Background(), 5*time.Second)
		defer c()
		_ = n.Interrupt(ctx)
	}()
	n.failed(errors.New(message))
	go n.server.Close()
}
func (n *NativeSession) request(method string, p Map, id any) {
	if method == "currentTime/read" {
		_ = n.server.Reply(id, Map{"currentTimeAt": time.Now().Unix()}, nil)
		return
	}
	n.mu.Lock()
	valid := !n.terminal && !n.retiredTurns[str(p["turnId"])] && str(p["threadId"]) == n.id && (str(p["turnId"]) == "" || n.turnID == "" || str(p["turnId"]) == n.turnID)
	reviewer := n.settings["approvalsReviewer"]
	n.mu.Unlock()
	if !valid {
		_ = n.server.Reply(id, nil, errors.New("Mokusei 找不到对应的活动 Codex turn"))
		return
	}
	interaction, e := ParseInteraction(method, p)
	if e != nil {
		_ = n.server.Reply(id, nil, &RPCError{Code: -32602, Message: e.Error()})
		return
	}
	if interaction == nil {
		_ = n.server.Reply(id, nil, &RPCError{Code: -32601, Message: "Unsupported Codex server request: " + method})
		return
	}
	n.mu.Lock()
	n.clearRetryLocked()
	n.mu.Unlock()
	if reviewer == "auto_review" {
		if grant := computerApproval(p); grant != nil {
			_ = n.server.Reply(id, grant, nil)
			return
		}
	}
	key := str(interaction["id"])
	pending := &nativePending{id: id, method: method, params: p, interaction: interaction}
	n.mu.Lock()
	if n.pending[key] != nil {
		n.mu.Unlock()
		_ = n.server.Reply(id, nil, errors.New("duplicate Codex interaction identity"))
		return
	}
	n.pending[key] = pending
	if ms := num(p["autoResolutionMs"]); ms > 0 {
		pending.timer = time.AfterFunc(time.Duration(ms)*time.Millisecond, func() {
			n.mu.Lock()
			if n.pending[key] != pending {
				n.mu.Unlock()
				return
			}
			delete(n.pending, key)
			n.mu.Unlock()
			_ = n.server.Reply(id, DefaultInteractionDecline(method), nil)
			n.publish(Map{"type": "interaction-closed", "interactionId": key, "resolution": "cancel"})
		})
	}
	n.mu.Unlock()
	n.publish(Map{"type": "interaction-opened", "interaction": interaction})
}
func (n *NativeSession) Close() error {
	n.closeOnce.Do(func() {
		n.mu.Lock()
		n.closed = true
		bridge := n.bridge
		id, turn, terminal := n.id, n.turnID, n.terminal
		n.mu.Unlock()
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		if !terminal && turn != "" {
			_, _ = n.server.Call(ctx, "turn/interrupt", Map{"threadId": id, "turnId": turn})
		}
		cancel()
		n.finish(Map{"status": "interrupted"})
		if bridge != nil {
			n.closeErr = bridge.Close()
		}
		n.closeErr = errors.Join(n.closeErr, n.server.Close())
	})
	return n.closeErr
}
func turnSettings(s Map, roots []string) Map {
	r := present(s, "model", "effort", "serviceTier", "personality", "approvalPolicy", "approvalsReviewer", "summary", "outputSchema")
	if p := obj(s["sandboxPolicy"]); len(p) > 0 {
		p = clone(p)
		if p["type"] == "workspaceWrite" && len(roots) > 0 {
			p["writableRoots"] = roots
		}
		r["sandboxPolicy"] = p
	} else {
		switch str(s["sandbox"]) {
		case "read-only":
			r["sandboxPolicy"] = Map{"type": "readOnly", "networkAccess": false}
		case "danger-full-access":
			r["sandboxPolicy"] = Map{"type": "dangerFullAccess"}
		case "workspace-write":
			r["sandboxPolicy"] = Map{"type": "workspaceWrite", "writableRoots": append([]string{}, roots...), "networkAccess": false, "excludeTmpdirEnvVar": false, "excludeSlashTmp": false}
		}
	}
	return r
}
func (n *NativeSession) exclusiveConfig(ctx context.Context, cwd string) (Map, error) {
	return ExclusiveToolsConfig(ctx, n.server, cwd)
}
func (n *NativeSession) supportsAutoReview(ctx context.Context, cwd string) (bool, error) {
	return SupportsAutoReview(ctx, n.server, cwd, n.server.initialized)
}
func (n *NativeSession) History(ctx context.Context, id string) ([]any, error) {
	out := []any{}
	seen := map[string]bool{}
	cursor := ""
	for {
		p := Map{"threadId": id, "itemsView": "full", "sortDirection": "asc", "limit": 100}
		if cursor != "" {
			p["cursor"] = cursor
		}
		r, e := n.server.Call(ctx, "thread/turns/list", p)
		if e != nil {
			return nil, e
		}
		page, ok := r["data"].([]any)
		if !ok {
			return nil, errors.New("Codex full native history unavailable")
		}
		for _, v := range page {
			turn := obj(v)
			if _, ok := turn["items"].([]any); !ok {
				return nil, errors.New("Codex native history missing items")
			}
			if view := str(turn["itemsView"]); view != "" && view != "full" {
				return nil, errors.New("Codex history is not full")
			}
		}
		out = append(out, page...)
		if len(jsonText(out)) > 8*1024*1024 {
			return nil, errors.New("Codex native history exceeds 8 MiB")
		}
		cursor = str(r["nextCursor"])
		if cursor == "" {
			return out, nil
		}
		if seen[cursor] {
			return nil, errors.New("Codex native history cursor did not advance")
		}
		seen[cursor] = true
	}
}
func (n *NativeSession) refreshBackground() error {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	return n.refreshBackgroundContext(ctx)
}
func (n *NativeSession) refreshBackgroundContext(ctx context.Context) error {
	n.refreshMu.Lock()
	defer n.refreshMu.Unlock()
	n.mu.Lock()
	id, closed, callback := n.id, n.closed, n.activity
	n.mu.Unlock()
	if closed || callback == nil {
		return errors.New("Codex background terminal observation unavailable")
	}
	terminals := map[string]Map{}
	seen := map[string]bool{}
	cursor := ""
	for {
		params := Map{"threadId": id, "limit": 1000}
		if cursor != "" {
			params["cursor"] = cursor
		}
		r, e := n.server.Call(ctx, "thread/backgroundTerminals/list", params)
		if e != nil {
			return e
		}
		page, ok := r["data"].([]any)
		if !ok {
			return errors.New("Codex background terminal observation unavailable")
		}
		for _, v := range page {
			i := obj(v)
			itemID := str(i["itemId"])
			if itemID == "" {
				return errors.New("Codex background terminal observation unavailable")
			}
			terminals[itemID] = Map{"id": itemID, "command": str(i["command"]), "cwd": str(i["cwd"])}
			if len(terminals) > 2000 {
				return errors.New("Codex background terminal observation unavailable")
			}
		}
		cursor = str(r["nextCursor"])
		if cursor == "" {
			break
		}
		if seen[cursor] {
			return errors.New("Codex background terminal observation unavailable")
		}
		seen[cursor] = true
	}
	n.mu.Lock()
	if n.closed {
		n.mu.Unlock()
		return errors.New("Codex background terminal observation unavailable")
	}
	completed := []string{}
	for id := range n.background {
		if terminals[id] == nil {
			completed = append(completed, id)
			n.tombstones[id] = true
		}
	}
	for id := range n.tombstones {
		if terminals[id] == nil {
			delete(n.tombstones, id)
		} else {
			delete(terminals, id)
		}
	}
	n.background = terminals
	values := []any{}
	for _, t := range terminals {
		values = append(values, t)
	}
	n.mu.Unlock()
	for _, activityID := range completed {
		callback(Map{"type": "background-activity-completed", "threadId": id, "activityId": activityID, "status": "completed", "detail": "Codex 后台终端已结束", "at": now()})
	}
	callback(Map{"type": "background-terminals", "threadId": id, "terminals": values, "at": now()})
	return nil
}
func (n *NativeSession) completeBackground(item Map) bool {
	if item["type"] != "commandExecution" {
		return false
	}
	id := str(item["id"])
	n.mu.Lock()
	tracked := n.background[id] != nil
	completed := n.tombstones[id]
	if tracked {
		delete(n.background, id)
		n.tombstones[id] = true
	}
	callback := n.activity
	threadID := n.id
	values := []any{}
	for _, t := range n.background {
		values = append(values, t)
	}
	n.mu.Unlock()
	if tracked && callback != nil {
		e := CompletedActivity(item)
		e["type"] = "background-activity-completed"
		e["threadId"] = threadID
		e["at"] = now()
		callback(e)
		callback(Map{"type": "background-terminals", "threadId": threadID, "terminals": values, "at": now()})
	}
	return tracked || completed
}

func (n *NativeSession) admitNative(turnID string) error {
	n.mu.Lock()
	admit := n.nativeAdmit
	n.mu.Unlock()
	if admit == nil {
		return errors.New("Native Codex turn has no registered owner")
	}
	executionID, e := admit(turnID)
	if e != nil {
		return e
	}
	n.mu.Lock()
	n.executionID = executionID
	n.turnID = turnID
	delete(n.retiredTurns, turnID)
	n.terminal = false
	n.failure = ""
	n.reasoning = map[string]string{}
	n.finals = map[string]string{}
	n.finalOrder = nil
	n.outputs = map[string]string{}
	n.seenUsage = map[string]bool{}
	n.completed = make(chan struct{})
	n.toolContext, n.toolCancel = context.WithCancel(context.Background())
	n.toolCalls = map[string]bool{}
	n.toolWorkers = &sync.WaitGroup{}
	n.mu.Unlock()
	n.server.mu.Lock()
	closed := n.server.closed
	failure := n.server.terminalErr
	n.server.mu.Unlock()
	if closed {
		n.failed(failure)
		return failure
	}
	return nil
}

func (n *NativeSession) validateSettings(ctx context.Context, o *NativeOptions) error {
	o.Settings = clone(o.Settings)
	if o.RequireExplicitSettings && str(o.Settings["serviceTier"]) == "" {
		return errors.New("Codex ordinary Thread requires an explicit serviceTier: default for standard speed (Fast off), or an advertised native tier")
	}
	if o.RequireExplicitSettings || o.Settings["thinking"] != nil || (o.Settings["model"] != nil && o.Settings["serviceTier"] != nil && o.Settings["permissionMode"] != nil) {
		models, e := ListModels(ctx, n.server)
		if e != nil {
			return e
		}
		if o.Settings["thinking"] != nil {
			if _, e = ValidateModelSettings(models, o.Settings, "execution settings"); e != nil {
				return e
			}
			effort, e := ThinkingEffort(o.Settings["thinking"])
			if e != nil {
				return e
			}
			delete(o.Settings, "thinking")
			delete(o.Settings, "effort")
			if effort != "" {
				o.Settings["effort"] = effort
			}
		} else {
			if _, e = ValidateExecutionModelSettings(models, o.Settings, "execution settings"); e != nil {
				return e
			}
		}
	} else if effort := str(o.Settings["effort"]); effort != "" {
		if strings.EqualFold(effort, "default") {
			delete(o.Settings, "effort")
		} else {
			models, e := ListModels(ctx, n.server)
			if ctx.Err() != nil {
				return ctx.Err()
			}
			selected := SelectModel(models, str(o.Settings["model"]))
			if e == nil && len(arr(selected["supportedReasoningEfforts"])) > 0 {
				supported := false
				for _, v := range arr(selected["supportedReasoningEfforts"]) {
					if strings.EqualFold(str(obj(v)["value"]), effort) {
						supported = true
					}
				}
				if !supported {
					delete(o.Settings, "effort")
				}
			} else if strings.EqualFold(effort, "minimal") {
				delete(o.Settings, "effort")
			}
		}
	}

	return nil
}

// Voice can emit native items and requests before its turn/started boundary.
// Keep their exact wire identity until the registered owner durably admits it.
func (n *NativeSession) routeNativePending(method string, p Map, id any) bool {
	threadID := str(p["threadId"])
	turnID := first(str(p["turnId"]), str(obj(p["turn"])["id"]))
	if turnID == "" || strings.HasPrefix(method, "thread/realtime/") {
		return false
	}
	n.mu.Lock()
	if n.nativeAdmit == nil || threadID != n.id || n.retiredTurns[turnID] || (!n.terminal && (n.turnID == "" || n.turnID == turnID)) || (method == "turn/started" && n.terminal) {
		n.mu.Unlock()
		return false
	}
	frame := Map{"method": method, "params": p, "id": id}
	size := len(jsonText(frame))
	if len(n.nativeBacklog) >= 1024 || n.nativeBacklogBytes+size > 8*1024*1024 {
		n.mu.Unlock()
		if id != nil {
			_ = n.server.Reply(id, nil, errors.New("native admission queue exceeded limit"))
		}
		n.protocolFailure("Codex native admission queue exceeded limit")
		return true
	}
	n.nativeBacklog = append(n.nativeBacklog, frame)
	n.nativeBacklogBytes += size
	n.mu.Unlock()
	return true
}
func (n *NativeSession) drainNativePending(turnID string) {
	n.mu.Lock()
	pending := []Map{}
	retained := []Map{}
	n.nativeBacklogBytes = 0
	for _, frame := range n.nativeBacklog {
		p := obj(frame["params"])
		id := first(str(p["turnId"]), str(obj(p["turn"])["id"]))
		if id == turnID {
			pending = append(pending, frame)
		} else {
			retained = append(retained, frame)
			n.nativeBacklogBytes += len(jsonText(frame))
		}
	}
	n.nativeBacklog = retained
	n.mu.Unlock()
	for _, frame := range pending {
		n.notification(str(frame["method"]), obj(frame["params"]), frame["id"])
	}
}

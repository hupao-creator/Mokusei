package tag

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"unicode/utf16"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/background"
)

type observationDecision struct {
	selection  plugin.OverviewFilterSelection
	tags       map[string]bool
	selectable map[string]bool
}
type observationRound struct {
	ctx       context.Context
	cancel    context.CancelFunc
	decisions map[string]observationDecision
}

// OverviewSelection retains one bounded live observation and consumes opaque
// decisions before native I/O, including failed or canceled selection attempts.
type OverviewSelection struct {
	overview plugin.OverviewControl
	lifetime context.Context
	scope    string
	mu       sync.Mutex
	round    *observationRound
}

func NewOverviewSelection(overview plugin.OverviewControl, lifetime context.Context, scope string) *OverviewSelection {
	selection := &OverviewSelection{overview: overview, lifetime: lifetime, scope: scope}
	context.AfterFunc(lifetime, func() { selection.invalidate(nil) })
	return selection
}
func (s *OverviewSelection) invalidate(expected *observationRound) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.round == nil || (expected != nil && s.round != expected) {
		return
	}
	s.round.cancel()
	s.round.decisions = map[string]observationDecision{}
	s.round = nil
}
func (s *OverviewSelection) Bindings() []plugin.ToolBinding {
	read := background.JSONPage(s.lifetime, "read_overview_context", "Read live desktop clients: current page, visibility/focus, selected thread and active follow-up composer, current/archive view, selected filter, actual selectable filters with member thread references, and recent user actions including submitted requests. A client displaying an active filter in this scope carries an opaque observationId for one selection; clients without one are read-only context, including the All view. An empty list means no connected overview. Offset/limit paginate a stable JSON snapshot; offset 0 refreshes and revokes all earlier observationIds.", model.Object{}, nil, func(ctx context.Context, _ model.Object, _ string) (any, error) { return s.observe(ctx) })
	execute := read.Execute
	read.Execute = func(ctx context.Context, call plugin.ToolCall) (json.RawMessage, error) {
		args, err := model.DecodeObject(call.Arguments)
		if err != nil {
			return nil, err
		}
		offset, err := background.Integer(args, "offset", 0)
		if err != nil {
			return nil, err
		}
		if offset == 0 {
			s.invalidate(nil)
		} else {
			s.mu.Lock()
			available := s.round != nil
			s.mu.Unlock()
			if !available {
				return nil, errors.New("Overview observation expired; restart at offset 0")
			}
		}
		s.mu.Lock()
		round := s.round
		s.mu.Unlock()
		stop := context.AfterFunc(ctx, func() {
			if round != nil {
				s.invalidate(round)
			}
		})
		defer stop()
		return execute(ctx, call)
	}
	selectTool := background.Tool(s.lifetime, "select_tag_filter", "Select a filter for the client identified by an observationId from the latest read_overview_context snapshot. The observationId is opaque and single-use; clients without one are read-only context. tag=null selects All; otherwise use an exact semantic tag from that observation. The scope's directory filter is context only and cannot be selected. This changes only the filter, without navigating or changing the current/archive view. Returns applied, unchanged, stale or unavailable; read fresh context before another decision. Does not edit tags or assignments.", model.Object{"observationId": model.Object{"type": "string", "minLength": 1}, "tag": model.Object{"anyOf": []any{model.Object{"type": "null"}, model.Object{"type": "string", "minLength": 1}}}}, []string{"observationId", "tag"}, func(ctx context.Context, args model.Object, _ string) (any, error) {
		id, err := background.String(args, "observationId")
		if err != nil {
			return nil, err
		}
		var tag *string
		if args["tag"] != nil {
			value, err := background.String(args, "tag")
			if err != nil {
				return nil, err
			}
			tag = &value
		}
		return s.selectFilter(ctx, id, tag)
	})
	return []plugin.ToolBinding{read, selectTool}
}
func (s *OverviewSelection) observe(ctx context.Context) (any, error) {
	s.invalidate(nil)
	lifetime, cancel := context.WithCancel(s.lifetime)
	round := &observationRound{ctx: lifetime, cancel: cancel, decisions: map[string]observationDecision{}}
	s.mu.Lock()
	s.round = round
	s.mu.Unlock()
	stop := context.AfterFunc(ctx, func() { s.invalidate(round) })
	defer stop()
	capture, cancelCapture := context.WithCancel(ctx)
	stopRound := context.AfterFunc(lifetime, cancelCapture)
	defer func() { stopRound(); cancelCapture() }()
	clients, err := s.overview.ReadClients(capture)
	if err != nil {
		s.invalidate(round)
		return nil, err
	}
	if err = capture.Err(); err != nil {
		s.invalidate(round)
		return nil, err
	}
	observations := []model.Object{}
	s.mu.Lock()
	if s.round != round {
		s.mu.Unlock()
		return nil, errors.New("Overview observation expired; read fresh context")
	}
	for _, client := range clients {
		filters := []plugin.OverviewFilter{}
		scoped := false
		for _, filter := range client.Filters {
			if filter.Scope != "" && filter.Scope != s.scope {
				continue
			}
			filters = append(filters, filter)
			if filter.Scope == s.scope {
				scoped = true
			}
		}
		// A client is visible for context when it shows this agent's scope. Only
		// a client with an active tag in that scope gets an observationId; the
		// All view stays read-only and cannot be selected.
		if s.scope != "" && !scoped {
			continue
		}
		client.Filters = filters
		// Thread references outside this scope's filters would let a scope agent
		// act on another workspace; classifiable would then reject the whole
		// assignment batch. Keep only refs backed by this scope's visible members.
		members := map[model.ThreadRef]bool{}
		for _, filter := range filters {
			for _, ref := range filter.Threads {
				members[ref] = true
			}
		}
		if client.SelectedThread != nil && !members[*client.SelectedThread] {
			client.SelectedThread = nil
		}
		if client.FollowUpThread != nil && !members[*client.FollowUpThread] {
			client.FollowUpThread = nil
		}
		actions := []plugin.OverviewUserAction{}
		for _, action := range client.RecentActions {
			if action.Thread != nil && !members[*action.Thread] {
				continue
			}
			actions = append(actions, action)
		}
		client.RecentActions = actions
		tags := map[string]bool{}
		selectable := map[string]bool{}
		for _, filter := range filters {
			tags[filter.Tag] = true
			// Directory filters identify the current scope view but are outside
			// the tag agent's authority as selection targets.
			if filter.Kind == "semantic" {
				selectable[filter.Tag] = true
			}
		}
		// A same-named tag can exist in several scopes. When the client reports
		// its selection scope, only an agent for that scope may act on it.
		canSelect := client.SelectedTag != nil && tags[*client.SelectedTag] &&
			(client.SelectedScope == nil || *client.SelectedScope == s.scope)
		id := ""
		if canSelect {
			id = background.UUID()
			round.decisions[id] = observationDecision{selection: plugin.OverviewFilterSelection{ClientID: client.ClientID, ContextID: client.ContextID, Revision: client.Revision}, tags: tags, selectable: selectable}
		}
		encoded, encodeErr := json.Marshal(client.OverviewClientContext)
		if encodeErr != nil {
			s.mu.Unlock()
			s.invalidate(round)
			return nil, encodeErr
		}
		public, decodeErr := model.DecodeObject(encoded)
		if decodeErr != nil {
			s.mu.Unlock()
			s.invalidate(round)
			return nil, decodeErr
		}
		delete(public, "contextId")
		delete(public, "revision")
		if id != "" {
			public["observationId"] = id
		}
		observations = append(observations, public)
	}
	s.mu.Unlock()
	encoded, err := json.Marshal(observations)
	if err != nil {
		s.invalidate(round)
		return nil, err
	}
	if len(utf16.Encode([]rune(string(encoded)))) > 64*1024*1024 {
		s.invalidate(round)
		return nil, errors.New("Overview observation is too large to capture")
	}
	return observations, nil
}
func (s *OverviewSelection) selectFilter(ctx context.Context, id string, tag *string) (any, error) {
	s.mu.Lock()
	round := s.round
	if round == nil {
		s.mu.Unlock()
		return model.Object{"status": "stale"}, nil
	}
	decision, ok := round.decisions[id]
	delete(round.decisions, id)
	s.mu.Unlock()
	if !ok || (tag != nil && !decision.selectable[*tag]) {
		return model.Object{"status": "stale"}, nil
	}
	selectionCtx, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(round.ctx, cancel)
	defer func() { stop(); cancel() }()
	if err := round.ctx.Err(); err != nil {
		return nil, err
	}
	decision.selection.Tag = tag
	if tag != nil {
		decision.selection.Scope = s.scope
	}
	result, err := s.overview.SelectFilter(selectionCtx, decision.selection)
	if err != nil {
		return nil, err
	}
	if err = selectionCtx.Err(); err != nil {
		return nil, err
	}
	return model.Object{"status": result.Status}, nil
}

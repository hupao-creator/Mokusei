package claude

import (
	"context"
	"encoding/json"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/sessioncache"
)

type claudeReaderRecord struct {
	raw         json.RawMessage
	executionID string
}

type claudeReaderSession struct {
	contentID string
	raw       json.RawMessage
	doc       *sessioncache.Document
	turns     []claudeReaderRecord
	size      int64

	scopes *sessioncache.Scopes
}

func newClaudeReaderSession(ctx context.Context, raw json.RawMessage, contentID string) (*claudeReaderSession, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	doc, err := sessioncache.ParseDocumentContext(ctx, raw)
	if err != nil {
		return nil, err
	}
	session := &claudeReaderSession{contentID: contentID, raw: raw, doc: doc, scopes: sessioncache.NewScopes(64, sessioncache.DefaultScopeBytes), size: int64(len(raw))}
	items, err := doc.ArrayContext(ctx, "turns")
	if err != nil {
		return nil, err
	}
	session.turns = make([]claudeReaderRecord, 0, len(items))
	for _, item := range items {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		var identity struct {
			ExecutionID string `json:"executionId"`
		}
		if err := json.Unmarshal(item, &identity); err != nil {
			return nil, err
		}
		session.turns = append(session.turns, claudeReaderRecord{raw: item, executionID: identity.ExecutionID})
	}
	return session, nil
}

func (s *claudeReaderSession) scopeState(ctx context.Context, scope model.RendererScope) (json.RawMessage, int64, error) {
	if scope.Kind != "turn" && scope.Kind != "execution" || model.IsNull(s.raw) {
		return s.raw, 0, nil
	}
	return s.scopes.Do(ctx, sessioncache.ScopeKey(scope), func(ctx context.Context) (json.RawMessage, error) {
		return s.buildExecutionState(ctx, scope)
	})
}

func (s *claudeReaderSession) buildExecutionState(ctx context.Context, scope model.RendererScope) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	fields := map[string]json.RawMessage{}
	for _, name := range []string{"version", "primarySessionId", "runtime", "nativeNotifications"} {
		if value, ok := s.doc.Field(name); ok {
			fields[name] = value
		}
	}
	turns := []json.RawMessage{}
	if scope.Key != "fork-history" {
		for _, record := range s.turns {
			if record.executionID == scope.Key {
				turns = append(turns, record.raw)
			}
		}
	}
	var err error
	if fields["turns"], err = sessioncache.EncodeArray(turns); err != nil {
		return nil, err
	}
	if scope.Key == "fork-history" {
		if value, ok := s.doc.Field("forkHistory"); ok {
			fields["forkHistory"] = value
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return sessioncache.Encode(fields)
}

func (a StateAdapter) ProjectReader(ctx context.Context, request plugin.ReaderRequest) (*plugin.ReaderSnapshot, error) {
	contentID := request.ContentID
	if contentID == "" {
		contentID = sessioncache.Identity(request.State)
	}
	if a.cache == nil {
		return projectClaudeReaderUncached(ctx, request, contentID)
	}
	handle, err := a.cache.Acquire(ctx, request.ThreadID, contentID, request.Generation, func(ctx context.Context, _ any, _ *sessioncache.Projections) (any, int64, error) {
		session, err := newClaudeReaderSession(ctx, request.State, contentID)
		if err != nil {
			return nil, 0, err
		}
		return session, session.size, nil
	})
	if err != nil {
		return nil, err
	}
	defer handle.Release()
	session := handle.Value.(*claudeReaderSession)
	state, scopeDelta, err := session.scopeState(ctx, request.Scope)
	if err != nil {
		return nil, err
	}
	handle.AddSize(scopeDelta)
	fingerprint := sessioncache.FingerprintString(contentID)
	if request.Scope.Kind == "turn" || request.Scope.Kind == "execution" {
		fingerprint = sessioncache.Fingerprint(state)
	}
	projection, delta, err := handle.Projections.Do(ctx, sessioncache.ScopeKey(request.Scope), fingerprint, func() (json.RawMessage, error) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		value, err := projectClaudeRenderer(state, request.Scope)
		if err == nil {
			err = ctx.Err()
		}
		return value, err
	})
	if err != nil {
		return nil, err
	}
	handle.AddSize(delta)
	if request.Known != nil && *request.Known == projection.Revision {
		return nil, nil
	}
	return &plugin.ReaderSnapshot{Revision: projection.Revision, Value: projection.Value}, nil
}

func projectClaudeReaderUncached(ctx context.Context, request plugin.ReaderRequest, contentID string) (*plugin.ReaderSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	session, err := newClaudeReaderSession(ctx, request.State, contentID)
	if err != nil {
		return nil, err
	}
	state, _, err := session.scopeState(ctx, request.Scope)
	if err != nil {
		return nil, err
	}
	value, err := projectClaudeRenderer(state, request.Scope)
	if err != nil {
		return nil, err
	}
	revision := sessioncache.Revision(value)
	if request.Known != nil && *request.Known == revision {
		return nil, nil
	}
	return &plugin.ReaderSnapshot{Revision: revision, Value: value}, nil
}

func (a StateAdapter) EvictThread(threadID string) {
	if a.cache != nil {
		a.cache.ReleaseThread(threadID)
	}
}

func (a StateAdapter) CacheStats() sessioncache.Stats {
	if a.cache == nil {
		return sessioncache.Stats{}
	}
	return a.cache.Stats()
}

func (a StateAdapter) closeReader() {
	if a.cache != nil {
		a.cache.Close()
	}
}

package codex

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/sessioncache"
)

type codexReaderRecord struct {
	raw         json.RawMessage
	executionID string
	updatedAt   int64
}

type codexReaderSession struct {
	contentID string
	raw       json.RawMessage
	doc       *sessioncache.Document
	turns     []codexReaderRecord
	history   []codexReaderRecord
	size      int64

	scopes *sessioncache.Scopes
}

func newCodexReaderSession(ctx context.Context, raw json.RawMessage, contentID string) (*codexReaderSession, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	doc, err := sessioncache.ParseDocumentContext(ctx, raw)
	if err != nil {
		return nil, err
	}
	session := &codexReaderSession{contentID: contentID, raw: raw, doc: doc, scopes: sessioncache.NewScopes(64, sessioncache.DefaultScopeBytes), size: int64(len(raw))}
	if session.turns, err = codexRecords(ctx, doc, "turns"); err != nil {
		return nil, err
	}
	if session.history, err = codexRecords(ctx, doc, "forkHistory"); err != nil {
		return nil, err
	}
	return session, nil
}

func codexRecords(ctx context.Context, doc *sessioncache.Document, field string) ([]codexReaderRecord, error) {
	items, err := doc.ArrayContext(ctx, field)
	if err != nil {
		return nil, err
	}
	records := make([]codexReaderRecord, 0, len(items))
	for _, item := range items {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		var identity struct {
			ExecutionID string `json:"executionId"`
			UpdatedAt   int64  `json:"updatedAt"`
		}
		if err := json.Unmarshal(item, &identity); err != nil {
			return nil, err
		}
		records = append(records, codexReaderRecord{raw: item, executionID: identity.ExecutionID, updatedAt: identity.UpdatedAt})
	}
	return records, nil
}

func (s *codexReaderSession) scopeState(ctx context.Context, scope model.RendererScope) (json.RawMessage, int64, error) {
	if scope.Kind != "turn" && scope.Kind != "execution" || model.IsNull(s.raw) {
		return s.raw, 0, nil
	}
	return s.scopes.Do(ctx, sessioncache.ScopeKey(scope), func(ctx context.Context) (json.RawMessage, error) {
		return s.buildExecutionState(ctx, scope)
	})
}

func (s *codexReaderSession) buildExecutionState(ctx context.Context, scope model.RendererScope) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	key := strings.TrimPrefix(scope.Key, "turn:")
	if !strings.HasPrefix(scope.Key, "turn:") {
		key = ""
	}
	current, inherited := codexFindReaderRecord(s.turns, key), codexFindReaderRecord(s.history, key)
	selected := current
	if selected == nil {
		selected = inherited
	}
	fields := map[string]json.RawMessage{}
	for _, name := range []string{"schema", "primarySessionId", "nativeActivity"} {
		if value, ok := s.doc.Field(name); ok {
			fields[name] = value
		}
	}
	updatedAt := int64(0)
	if selected != nil {
		updatedAt = max(updatedAt, selected.updatedAt)
	}
	if value, ok := s.doc.Field("nativeActivity"); ok {
		var activity struct {
			UpdatedAt int64 `json:"updatedAt"`
		}
		if err := json.Unmarshal(value, &activity); err != nil {
			return nil, err
		}
		updatedAt = max(updatedAt, activity.UpdatedAt)
	}
	fields["updatedAt"] = json.RawMessage(strconv.FormatInt(updatedAt, 10))
	terminals, err := s.doc.ArrayContext(ctx, "backgroundTerminals")
	if err != nil {
		return nil, err
	}
	if len(terminals) > 32 {
		terminals = terminals[len(terminals)-32:]
	}
	if fields["backgroundTerminals"], err = sessioncache.EncodeArray(terminals); err != nil {
		return nil, err
	}
	turns := []json.RawMessage{}
	if current != nil {
		turns = append(turns, current.raw)
	}
	if fields["turns"], err = sessioncache.EncodeArray(turns); err != nil {
		return nil, err
	}
	if current == nil && inherited != nil {
		history := []json.RawMessage{inherited.raw}
		if fields["forkHistory"], err = sessioncache.EncodeArray(history); err != nil {
			return nil, err
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return sessioncache.Encode(fields)
}

func codexFindReaderRecord(records []codexReaderRecord, id string) *codexReaderRecord {
	for i := range records {
		if records[i].executionID == id {
			return &records[i]
		}
	}
	return nil
}

func (a sessionStateAdapter) ProjectReader(ctx context.Context, request plugin.ReaderRequest) (*plugin.ReaderSnapshot, error) {
	contentID := request.ContentID
	if contentID == "" {
		contentID = sessioncache.Identity(request.State)
	}
	if a.cache == nil {
		return projectCodexReaderUncached(ctx, request, contentID)
	}
	handle, err := a.cache.Acquire(ctx, request.ThreadID, contentID, request.Generation, func(ctx context.Context, _ any, _ *sessioncache.Projections) (any, int64, error) {
		session, err := newCodexReaderSession(ctx, request.State, contentID)
		if err != nil {
			return nil, 0, err
		}
		return session, session.size, nil
	})
	if err != nil {
		return nil, err
	}
	defer handle.Release()
	session := handle.Value.(*codexReaderSession)
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
		value, err := projectCodexRenderer(state, request.Scope)
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

func projectCodexReaderUncached(ctx context.Context, request plugin.ReaderRequest, contentID string) (*plugin.ReaderSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	session, err := newCodexReaderSession(ctx, request.State, contentID)
	if err != nil {
		return nil, err
	}
	state, _, err := session.scopeState(ctx, request.Scope)
	if err != nil {
		return nil, err
	}
	value, err := projectCodexRenderer(state, request.Scope)
	if err != nil {
		return nil, err
	}
	revision := sessioncache.Revision(value)
	if request.Known != nil && *request.Known == revision {
		return nil, nil
	}
	return &plugin.ReaderSnapshot{Revision: revision, Value: value}, nil
}

func (a sessionStateAdapter) EvictThread(threadID string) {
	if a.cache != nil {
		a.cache.ReleaseThread(threadID)
	}
}

func (a sessionStateAdapter) CacheStats() sessioncache.Stats {
	if a.cache == nil {
		return sessioncache.Stats{}
	}
	return a.cache.Stats()
}

func (a sessionStateAdapter) closeReader() {
	if a.cache != nil {
		a.cache.Close()
	}
}

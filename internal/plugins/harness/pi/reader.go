package pi

import (
	"context"
	"encoding/json"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/sessioncache"
)

type piReaderRecord struct {
	raw         json.RawMessage
	executionID string
}

type piReaderSession struct {
	contentID   string
	raw         json.RawMessage
	doc         *sessioncache.Document
	messages    []piReaderRecord
	executions  []piReaderRecord
	foregrounds []piReaderRecord
	latest      string
	size        int64

	scopes *sessioncache.Scopes
}

func newPiReaderSession(ctx context.Context, raw json.RawMessage, contentID string) (*piReaderSession, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	doc, err := sessioncache.ParseDocumentContext(ctx, raw)
	if err != nil {
		return nil, err
	}
	session := &piReaderSession{contentID: contentID, raw: raw, doc: doc, scopes: sessioncache.NewScopes(64, sessioncache.DefaultScopeBytes), size: int64(len(raw))}
	if session.messages, err = piRecords(ctx, doc, "messages"); err != nil {
		return nil, err
	}
	if session.executions, err = piRecords(ctx, doc, "executions"); err != nil {
		return nil, err
	}
	if session.foregrounds, err = piRecords(ctx, doc, "foregrounds"); err != nil {
		return nil, err
	}
	if value, ok := doc.Field("latestExecutionId"); ok {
		if err := json.Unmarshal(value, &session.latest); err != nil {
			return nil, err
		}
	}
	return session, nil
}

func piRecords(ctx context.Context, doc *sessioncache.Document, field string) ([]piReaderRecord, error) {
	items, err := doc.ArrayContext(ctx, field)
	if err != nil {
		return nil, err
	}
	records := make([]piReaderRecord, 0, len(items))
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
		records = append(records, piReaderRecord{raw: item, executionID: identity.ExecutionID})
	}
	return records, nil
}

func (s *piReaderSession) scopeState(ctx context.Context, scope model.RendererScope) (json.RawMessage, int64, error) {
	if scope.Kind != "turn" && scope.Kind != "execution" {
		return s.raw, 0, nil
	}
	return s.scopes.Do(ctx, sessioncache.ScopeKey(scope), func(ctx context.Context) (json.RawMessage, error) {
		return s.buildExecutionState(ctx, scope)
	})
}

func (s *piReaderSession) buildExecutionState(ctx context.Context, scope model.RendererScope) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	fields := map[string]json.RawMessage{}
	if value, ok := s.doc.Field("version"); ok {
		fields["version"] = value
	} else {
		fields["version"] = json.RawMessage("1")
	}
	messages := []json.RawMessage{}
	for _, record := range s.messages {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if record.executionID == scope.Key {
			messages = append(messages, record.raw)
		}
	}
	executions := []json.RawMessage{}
	for _, record := range s.executions {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if record.executionID == scope.Key {
			executions = append(executions, record.raw)
		}
	}
	foregrounds := []json.RawMessage{}
	for _, record := range s.foregrounds {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if record.executionID == scope.Key {
			foregrounds = append(foregrounds, record.raw)
		}
	}
	var err error
	if fields["messages"], err = sessioncache.EncodeArray(messages); err != nil {
		return nil, err
	}
	if fields["executions"], err = sessioncache.EncodeArray(executions); err != nil {
		return nil, err
	}
	if _, exists := s.doc.Field("foregrounds"); exists {
		if fields["foregrounds"], err = sessioncache.EncodeArray(foregrounds); err != nil {
			return nil, err
		}
	}
	if value, exists := s.doc.Field("executionAuthors"); exists {
		var authors map[string]json.RawMessage
		if err := json.Unmarshal(value, &authors); err != nil {
			return nil, err
		}
		if author, ok := authors[scope.Key]; ok {
			encoded, err := sessioncache.EncodeObject(map[string]json.RawMessage{scope.Key: author})
			if err != nil {
				return nil, err
			}
			fields["executionAuthors"] = encoded
		}
	}
	if s.latest == scope.Key {
		if value, ok := s.doc.Field("latestExecutionId"); ok {
			fields["latestExecutionId"] = value
		} else {
			fields["latestExecutionId"] = json.RawMessage(`"` + scope.Key + `"`)
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return sessioncache.Encode(fields)
}

func (a stateAdapter) ProjectReader(ctx context.Context, request plugin.ReaderRequest) (*plugin.ReaderSnapshot, error) {
	contentID := request.ContentID
	if contentID == "" {
		contentID = sessioncache.Identity(request.State)
	}
	if a.cache == nil {
		return projectPiReaderUncached(ctx, request, contentID)
	}
	handle, err := a.cache.Acquire(ctx, request.ThreadID, contentID, request.Generation, func(ctx context.Context, _ any, _ *sessioncache.Projections) (any, int64, error) {
		session, err := newPiReaderSession(ctx, request.State, contentID)
		if err != nil {
			return nil, 0, err
		}
		return session, session.size, nil
	})
	if err != nil {
		return nil, err
	}
	defer handle.Release()
	session := handle.Value.(*piReaderSession)
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
		value, err := projectPiRenderer(state, request.Scope)
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

func projectPiReaderUncached(ctx context.Context, request plugin.ReaderRequest, contentID string) (*plugin.ReaderSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	session, err := newPiReaderSession(ctx, request.State, contentID)
	if err != nil {
		return nil, err
	}
	state, _, err := session.scopeState(ctx, request.Scope)
	if err != nil {
		return nil, err
	}
	value, err := projectPiRenderer(state, request.Scope)
	if err != nil {
		return nil, err
	}
	revision := sessioncache.Revision(value)
	if request.Known != nil && *request.Known == revision {
		return nil, nil
	}
	return &plugin.ReaderSnapshot{Revision: revision, Value: value}, nil
}

func (a stateAdapter) EvictThread(threadID string) {
	if a.cache != nil {
		a.cache.ReleaseThread(threadID)
	}
}

func (a stateAdapter) CacheStats() sessioncache.Stats {
	if a.cache == nil {
		return sessioncache.Stats{}
	}
	return a.cache.Stats()
}

func (a stateAdapter) closeReader() {
	if a.cache != nil {
		a.cache.Close()
	}
}

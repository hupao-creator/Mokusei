package opencode

import (
	"context"
	"encoding/json"
	"strconv"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/sessioncache"
)

// readerRecord keeps the smallest identity needed to select one execution's
// stored records. Bodies stay as raw slices; only the requested scope is ever
// decoded.
type readerRecord struct {
	raw         json.RawMessage
	id          string
	executionID string
	inherited   bool
}

type opencodeReaderSession struct {
	contentID    string
	raw          json.RawMessage
	doc          *sessioncache.Document
	messages     []readerRecord
	executions   []readerRecord
	interactions []readerRecord
	auxiliary    []readerRecord
	foregrounds  []readerRecord
	latest       string
	size         int64

	scopes *sessioncache.Scopes
}

func newOpencodeReaderSession(ctx context.Context, raw json.RawMessage, contentID string) (*opencodeReaderSession, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	doc, err := sessioncache.ParseDocumentContext(ctx, raw)
	if err != nil {
		return nil, err
	}
	session := &opencodeReaderSession{contentID: contentID, raw: raw, doc: doc, scopes: sessioncache.NewScopes(64, sessioncache.DefaultScopeBytes), size: int64(len(raw))}
	session.messages, err = opencodeRecords(ctx, doc, "messages")
	if err != nil {
		return nil, err
	}
	session.executions, err = opencodeRecords(ctx, doc, "executions")
	if err != nil {
		return nil, err
	}
	session.interactions, err = opencodeRecords(ctx, doc, "interactions")
	if err != nil {
		return nil, err
	}
	session.auxiliary, err = opencodeRecords(ctx, doc, "auxiliaryUsage")
	if err != nil {
		return nil, err
	}
	session.foregrounds, err = opencodeRecords(ctx, doc, "foregrounds")
	if err != nil {
		return nil, err
	}
	if value, ok := doc.Field("latestExecutionId"); ok {
		if err := json.Unmarshal(value, &session.latest); err != nil {
			return nil, err
		}
	}
	return session, nil
}

func opencodeRecords(ctx context.Context, doc *sessioncache.Document, field string) ([]readerRecord, error) {
	items, err := doc.ArrayContext(ctx, field)
	if err != nil {
		return nil, err
	}
	records := make([]readerRecord, 0, len(items))
	for _, item := range items {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		var identity struct {
			ID          string `json:"id"`
			ExecutionID string `json:"executionId"`
			Inherited   bool   `json:"inherited"`
		}
		if err := json.Unmarshal(item, &identity); err != nil {
			return nil, err
		}
		records = append(records, readerRecord{raw: item, id: identity.ID, executionID: identity.ExecutionID, inherited: identity.Inherited})
	}
	return records, nil
}

func (s *opencodeReaderSession) scopeState(ctx context.Context, scope model.RendererScope) (json.RawMessage, int64, error) {
	if scope.Kind != "turn" && scope.Kind != "execution" {
		return s.raw, 0, nil
	}
	return s.scopes.Do(ctx, sessioncache.ScopeKey(scope), func(ctx context.Context) (json.RawMessage, error) {
		return s.buildExecutionState(ctx, scope)
	})
}

func (s *opencodeReaderSession) buildExecutionState(ctx context.Context, scope model.RendererScope) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	history := scope.Key == "opencode-fork-history"
	fields := map[string]json.RawMessage{}
	if value, ok := s.doc.Field("version"); ok {
		fields["version"] = value
	} else {
		fields["version"] = json.RawMessage("1")
	}
	if value, ok := s.doc.Field("nativeSessionId"); ok {
		fields["nativeSessionId"] = value
	}
	if _, ok := s.doc.Field("backgroundSessions"); ok {
		items, err := s.doc.ArrayContext(ctx, "backgroundSessions")
		if err != nil {
			return nil, err
		}
		if len(items) > 32 {
			items = items[len(items)-32:]
		}
		encoded, err := sessioncache.EncodeArray(items)
		if err != nil {
			return nil, err
		}
		fields["backgroundSessions"] = encoded
	}
	if _, ok := s.doc.Field("backgroundShells"); ok {
		items, err := s.doc.ArrayContext(ctx, "backgroundShells")
		if err != nil {
			return nil, err
		}
		if len(items) > 32 {
			items = items[len(items)-32:]
		}
		encoded, err := sessioncache.EncodeArray(items)
		if err != nil {
			return nil, err
		}
		fields["backgroundShells"] = encoded
	}
	if history {
		if value, ok := s.doc.Field("forkSource"); ok {
			fields["forkSource"] = value
		}
	}
	if s.latest == scope.Key && !history {
		if value, ok := s.doc.Field("latestExecutionId"); ok {
			fields["latestExecutionId"] = value
		} else {
			fields["latestExecutionId"] = json.RawMessage(strconv.Quote(scope.Key))
		}
	}
	executions := []json.RawMessage{}
	if !history {
		for _, record := range s.executions {
			if record.executionID == scope.Key {
				executions = append(executions, record.raw)
			}
		}
	}
	messages := []json.RawMessage{}
	for _, record := range s.messages {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if history && record.inherited || !history && !record.inherited && record.executionID == scope.Key {
			messages = append(messages, record.raw)
		}
	}
	interactions := []json.RawMessage{}
	if !history {
		for _, record := range s.interactions {
			if record.executionID == scope.Key {
				interactions = append(interactions, record.raw)
			}
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
	auxiliary := []json.RawMessage{}
	for _, record := range s.auxiliary {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if record.executionID == scope.Key {
			auxiliary = append(auxiliary, record.raw)
		}
	}
	var err error
	if fields["executions"], err = sessioncache.EncodeArray(executions); err != nil {
		return nil, err
	}
	if fields["messages"], err = sessioncache.EncodeArray(messages); err != nil {
		return nil, err
	}
	if fields["interactions"], err = sessioncache.EncodeArray(interactions); err != nil {
		return nil, err
	}
	if _, exists := s.doc.Field("foregrounds"); exists {
		if fields["foregrounds"], err = sessioncache.EncodeArray(foregrounds); err != nil {
			return nil, err
		}
	}
	if _, exists := s.doc.Field("auxiliaryUsage"); exists {
		if fields["auxiliaryUsage"], err = sessioncache.EncodeArray(auxiliary); err != nil {
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
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return sessioncache.Encode(fields)
}

func projectOpenCodeReaderState(raw json.RawMessage, scope model.RendererScope) (json.RawMessage, error) {
	return projectOpenCodeRenderer(raw, scope)
}

func (a StateAdapter) ProjectReader(ctx context.Context, request plugin.ReaderRequest) (*plugin.ReaderSnapshot, error) {
	contentID := request.ContentID
	if contentID == "" {
		contentID = sessioncache.Identity(request.State)
	}
	if a.cache == nil {
		return projectOpenCodeReaderUncached(ctx, request, contentID)
	}
	handle, err := a.cache.Acquire(ctx, request.ThreadID, contentID, request.Generation, func(ctx context.Context, _ any, _ *sessioncache.Projections) (any, int64, error) {
		session, err := newOpencodeReaderSession(ctx, request.State, contentID)
		if err != nil {
			return nil, 0, err
		}
		return session, session.size, nil
	})
	if err != nil {
		return nil, err
	}
	defer handle.Release()
	session := handle.Value.(*opencodeReaderSession)
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
		value, err := projectOpenCodeReaderState(state, request.Scope)
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

func projectOpenCodeReaderUncached(ctx context.Context, request plugin.ReaderRequest, contentID string) (*plugin.ReaderSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	session, err := newOpencodeReaderSession(ctx, request.State, contentID)
	if err != nil {
		return nil, err
	}
	state, _, err := session.scopeState(ctx, request.Scope)
	if err != nil {
		return nil, err
	}
	value, err := projectOpenCodeReaderState(state, request.Scope)
	if err != nil {
		return nil, err
	}
	if request.Known != nil && *request.Known == sessioncache.Revision(value) {
		return nil, nil
	}
	return &plugin.ReaderSnapshot{Revision: sessioncache.Revision(value), Value: value}, nil
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

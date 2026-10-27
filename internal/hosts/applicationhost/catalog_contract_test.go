package applicationhost

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type catalogContractFixture struct{ tags model.TagProjection }

func (f catalogContractFixture) Project(model.ApplicationThreadRecord) (model.TagProjection, error) {
	return f.tags, nil
}
func (catalogContractFixture) Sources(model.ApplicationThreadRecord) ([]model.ThreadRef, error) {
	return nil, nil
}
func (catalogContractFixture) Apply(model.ApplicationThreadRecord, plugin.SemanticTagEffect) (plugin.ThreadStateChange, error) {
	return plugin.ThreadStateChange{}, nil
}
func (catalogContractFixture) ReadSession(r model.ApplicationThreadRecord) (*model.SessionRecord, error) {
	return &model.SessionRecord{ID: r.ID, HarnessID: "fixture", SessionState: json.RawMessage(`{}`), Settings: json.RawMessage(`{}`)}, nil
}
func (catalogContractFixture) InitialConfiguration(model.ApplicationThreadRecord) (plugin.ConversationConfiguration, error) {
	return plugin.ConversationConfiguration{}, nil
}
func (catalogContractFixture) WithSession(model.ApplicationThreadRecord, model.SessionRecord) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}

func TestConversationProjectionCarriesCurrentSemanticDecoration(t *testing.T) {
	host := &Host{config: Config{ProjectSession: func(_ context.Context, s model.SessionRecord) (model.SessionRecord, error) { return s, nil }}}
	var entries []model.ApplicationThread
	for _, tagged := range []bool{false, true} {
		fixture := catalogContractFixture{tags: model.TagProjection{Tags: []string{"Backend", "Repo"}, SemanticTags: []string{"Backend"}, DirectoryTags: []string{"Repo"}, TagEmojis: map[string]string{"Backend": "👩🏽‍💻"}}}
		definition := plugin.ThreadTypeDefinition{
			Contract: plugin.ValueContract{ID: "fixture", SchemaVersion: 1, Parse: func(raw json.RawMessage) (json.RawMessage, error) { return raw, nil }},
			Project: func(model.ApplicationThreadRecord) (plugin.ThreadProjection, error) {
				return plugin.ThreadProjection{Title: "Conversation", View: json.RawMessage(`{}`)}, nil
			},
			Conversation: fixture,
		}
		if tagged {
			definition.Tags = fixture
		}
		entry, err := host.projectThread(t.Context(), definition, model.ApplicationThreadRecord{VersionedRecord: model.VersionedRecord{ID: "conversation"}, Ref: model.ThreadRef{ThreadID: "conversation", TypeID: "fixture"}})
		if err != nil {
			t.Fatal(err)
		}
		entries = append(entries, entry)
		var presentation struct {
			Thread model.ThreadRecord `json:"thread"`
		}
		if err := json.Unmarshal(entry.Presentations[0].Value, &presentation); err != nil {
			t.Fatal(err)
		}
		if presentation.Thread.TagEmojis == nil || !reflect.DeepEqual(presentation.Thread.Tags, entry.Tags.SemanticTags) || !reflect.DeepEqual(presentation.Thread.TagEmojis, entry.Tags.TagEmojis) {
			t.Fatalf("conversation violated required semantic decoration: %+v, projection: %+v", presentation.Thread, entry.Tags)
		}
	}
	if path := os.Getenv("MOKUSEI_CONVERSATION_CONTRACT_EXPORT"); path != "" {
		data, err := json.Marshal(entries)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
}

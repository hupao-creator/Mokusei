package report

import (
	"encoding/json"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// Startup refreshes application projections from live task snapshots. A Report
// persisted while its task lived in a linked worktree must therefore lose the
// stale worktree label without a database migration.
func TestApplyReplacesPersistedWorktreeDirectoryTag(t *testing.T) {
	const bad = "task-fd71335e-bfa-1c13e467e2e6e0adf36974155175c5fb"
	const repository = "Mokusei"
	ref := model.ThreadRef{ThreadID: "thread-1", TypeID: "agent"}
	value := Data{
		Scope:           "/projects/Mokusei",
		Title:           "Report",
		HTML:            "<p>ok</p>",
		ContentRevision: "content-1",
		RelatedExecutions: []model.ExecutionRef{
			{Thread: ref, ExecutionID: "execution-1"},
		},
		TagSources: map[string]TagSource{
			"thread-1": {TagEmojis: map[string]string{}, SemanticTags: []string{}, DirectoryTags: []string{bad}},
		},
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	record := model.ApplicationThreadRecord{
		VersionedRecord: model.VersionedRecord{ID: "report-1", Revision: 1, Value: encoded},
		Ref:             model.ThreadRef{ThreadID: "report-1", TypeID: "report"},
	}
	change, err := (threadExtensions{}).Apply(record, plugin.SemanticTagEffect{
		SourceThreads: []plugin.ThreadTagSnapshot{{
			Thread: ref,
			Tags: model.TagProjection{
				Tags:          []string{repository},
				TagEmojis:     map[string]string{},
				SemanticTags:  []string{},
				DirectoryTags: []string{repository},
			},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	updated, err := ParseData(change.Value)
	if err != nil {
		t.Fatal(err)
	}
	projection := ProjectTags(updated)
	if len(projection.DirectoryTags) != 1 || projection.DirectoryTags[0] != repository {
		t.Fatalf("DirectoryTags = %v, want [%s]", projection.DirectoryTags, repository)
	}
	for _, tag := range projection.Tags {
		if tag == bad {
			t.Fatalf("stale worktree tag survived: %v", projection.Tags)
		}
	}
}

// A Report can outlive its source thread. Once the live snapshot disappears the
// source directory label is cleared while the owning scope remains stable.
func TestApplyClearsDirectoryTagForMissingSourceThread(t *testing.T) {
	const bad = "task-fd71335e-bfa-1c13e467e2e6e0adf36974155175c5fb"
	ref := model.ThreadRef{ThreadID: "thread-1", TypeID: "agent"}
	value := Data{
		Scope:           "/projects/Mokusei",
		Title:           "Report",
		HTML:            "<p>ok</p>",
		ContentRevision: "content-1",
		RelatedExecutions: []model.ExecutionRef{
			{Thread: ref, ExecutionID: "execution-1"},
		},
		TagSources: map[string]TagSource{
			"thread-1": {TagEmojis: map[string]string{"Keep": "👩🏽‍💻"}, SemanticTags: []string{"Keep"}, DirectoryTags: []string{bad}},
		},
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	record := model.ApplicationThreadRecord{
		VersionedRecord: model.VersionedRecord{ID: "report-1", Revision: 1, Value: encoded},
		Ref:             model.ThreadRef{ThreadID: "report-1", TypeID: "report"},
	}
	change, err := (threadExtensions{}).Apply(record, plugin.SemanticTagEffect{
		SourceThreads: []plugin.ThreadTagSnapshot{},
	})
	if err != nil {
		t.Fatal(err)
	}
	updated, err := ParseData(change.Value)
	if err != nil {
		t.Fatal(err)
	}
	projection := ProjectTags(updated)
	if len(projection.DirectoryTags) != 1 || projection.DirectoryTags[0] != "Mokusei" {
		t.Fatalf("DirectoryTags = %v, want persistent owning directory", projection.DirectoryTags)
	}
	if projection.TagEmojis["Keep"] != "👩🏽‍💻" {
		t.Fatalf("deleted source lost its semantic emoji: %v", projection.TagEmojis)
	}
	if len(projection.SemanticTags) != 1 || projection.SemanticTags[0] != "Keep" {
		t.Fatalf("SemanticTags = %v, want [Keep]", projection.SemanticTags)
	}
	for _, tag := range projection.Tags {
		if tag == bad {
			t.Fatalf("stale worktree tag survived: %v", projection.Tags)
		}
	}
}

func TestReportEmojiContractAndNormalizedSourceInheritance(t *testing.T) {
	value := Data{
		Scope: "/projects/Repo",
		Title: "Report", HTML: "<p>ok</p>", ContentRevision: "content-1",
		RelatedExecutions: []model.ExecutionRef{
			{Thread: model.ThreadRef{ThreadID: "first", TypeID: "agent"}, ExecutionID: "execution-1"},
			{Thread: model.ThreadRef{ThreadID: "second", TypeID: "agent"}, ExecutionID: "execution-2"},
		},
		TagSources: map[string]TagSource{
			"first":  {SemanticTags: []string{"Backend"}, DirectoryTags: []string{"Repo"}, TagEmojis: map[string]string{"Backend": "👩🏽‍💻"}},
			"second": {SemanticTags: []string{"ＢＡＣＫＥＮＤ"}, DirectoryTags: []string{}, TagEmojis: map[string]string{"ＢＡＣＫＥＮＤ": "🔧"}},
		},
	}
	parse := func() (Data, error) {
		raw, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		return ParseData(raw)
	}
	decoded, err := parse()
	if err != nil {
		t.Fatal(err)
	}
	projection := ProjectTags(decoded)
	if len(projection.SemanticTags) != 1 || projection.SemanticTags[0] != "Backend" || len(projection.TagEmojis) != 1 || projection.TagEmojis["Backend"] != "👩🏽‍💻" {
		t.Fatalf("projection did not keep first source identity and emoji: %+v", projection)
	}
	for _, emojis := range []map[string]string{nil, {}, {"Other": "🔧"}, {"Backend": "👩‍"}} {
		source := value.TagSources["first"]
		source.TagEmojis = emojis
		value.TagSources["first"] = source
		if _, err := parse(); err == nil {
			t.Fatalf("accepted malformed source decoration: %v", emojis)
		}
	}
}

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
)

// verifyScopedTagPools exercises the production capability surface with two
// real scopes: the directory scope of two ordinary threads and the inbox scope
// owned by the original temporary-workspace thread.
func verifyScopedTagPools(ctx context.Context, r *core.Runtime, inboxThreadID string) {
	input := model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "scoped tag fixture"}}}
	// The runtime data root matches the managed temporary-workspace patterns.
	// Use an unrelated /tmp root so this fixture is a real directory scope.
	projectRoot, err := os.MkdirTemp("/tmp", "scoped-tags-")
	must(err)
	defer os.RemoveAll(projectRoot)
	projectDir := filepath.Join(projectRoot, "project")
	must(os.MkdirAll(projectDir, 0o700))
	project, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Cwd: projectDir, Input: input})
	must(err)
	second, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Cwd: projectDir, Input: input})
	must(err)
	scope := directorytag.Scope(projectDir)
	if scope == directorytag.InboxScope {
		panic("directory thread collapsed into inbox scope")
	}
	projectRead, projectWrite := scopedTagCapabilities(r, scope, "tag.agent.verify-project")
	inboxRead, inboxWrite := scopedTagCapabilities(r, directorytag.InboxScope, "tag.agent.verify-inbox")

	must(projectWrite.EnsureInventory(ctx))
	if _, err := projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "create", Name: filepath.Base(projectDir), Emoji: stringPointer("🔧")}, plugin.BackgroundWriteOptions{RequestID: "project-label"}); err == nil {
		panic("scope accepted a tag that duplicates its directory label")
	}
	if _, err := projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "create-many", Definitions: []plugin.SemanticTagInput{{Name: "Alpha", Emoji: "👩🏽‍💻"}, {Name: "Beta", Emoji: "🇨🇳"}, {Name: "Gamma", Emoji: "invalid"}, {Name: "Delta", Emoji: "1️⃣"}, {Name: "Epsilon", Emoji: "🧭"}}}, plugin.BackgroundWriteOptions{RequestID: "project-create"}); err != nil {
		panic(err)
	}
	if _, err := projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "create", Name: "Zeta", Emoji: stringPointer("🔧")}, plugin.BackgroundWriteOptions{RequestID: "project-overflow"}); err == nil {
		panic("scope accepted a sixth tag")
	}
	projectRef := model.ThreadRef{ThreadID: project.Record.ID, TypeID: "agent"}
	secondRef := model.ThreadRef{ThreadID: second.Record.ID, TypeID: "agent"}
	inboxRef := model.ThreadRef{ThreadID: inboxThreadID, TypeID: "agent"}

	for _, invalid := range [][]string{{}, {"Alpha", "Beta"}, {"Unknown"}} {
		if _, err := projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "assign", Thread: &projectRef, Tags: invalid}, plugin.BackgroundWriteOptions{RequestID: "project-invalid"}); err == nil {
			panic("invalid single assignment accepted")
		}
	}
	if _, err := projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "assign", Thread: &projectRef, Tags: []string{"Alpha"}}, plugin.BackgroundWriteOptions{RequestID: "project-assign"}); err != nil {
		panic(err)
	}
	// One invalid entry must roll back the valid entry in the same batch.
	if _, err := projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "assign-many", Assignments: []plugin.SemanticTagAssignment{
		{Thread: projectRef, Tags: []string{"Delta"}},
		{Thread: inboxRef, Tags: []string{"Beta"}},
	}}, plugin.BackgroundWriteOptions{RequestID: "project-batch"}); err == nil {
		panic("cross-scope batch accepted")
	}
	assertThreadTags(r, projectRef.ThreadID, "Alpha")
	assertTagEmoji(r, projectRef.ThreadID, "Alpha", "👩🏽‍💻")
	// NFKC/case/whitespace cannot consume a second slot, even when
	// generation returns a different icon.
	_, err = projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "create", Name: " ＡＬＰＨＡ ", Emoji: stringPointer("🔧")}, plugin.BackgroundWriteOptions{RequestID: "project-dedup"})
	must(err)
	assertTagEmoji(r, projectRef.ThreadID, "Alpha", "👩🏽‍💻")
	if _, err := inboxWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "assign", Thread: &projectRef, Tags: []string{"Alpha"}}, plugin.BackgroundWriteOptions{RequestID: "inbox-cross-scope"}); err == nil {
		panic("inbox capability wrote a directory-scope thread")
	}

	if _, err := projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "update", Name: "Alpha", NewName: "First"}, plugin.BackgroundWriteOptions{RequestID: "project-rename"}); err != nil {
		panic(err)
	}
	assertThreadTags(r, projectRef.ThreadID, "First")
	assertTagEmoji(r, projectRef.ThreadID, "First", "👩🏽‍💻")
	before, err := r.Thread(projectRef.ThreadID)
	must(err)
	_, err = projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "update", Name: "First", Emoji: stringPointer("❤️")}, plugin.BackgroundWriteOptions{RequestID: "project-emoji-only"})
	must(err)
	assertTagEmoji(r, projectRef.ThreadID, "First", "❤️")
	after, err := r.Thread(projectRef.ThreadID)
	must(err)
	if after.Revision <= before.Revision || after.Title != before.Title {
		panic("emoji update did not publish or changed thread title")
	}
	_, err = projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "update", Name: "First", Emoji: stringPointer("bad output")}, plugin.BackgroundWriteOptions{RequestID: "project-invalid-emoji"})
	must(err)
	assertTagEmoji(r, projectRef.ThreadID, "First", "🏷️")

	if _, err := projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "assign", Thread: &secondRef, Tags: []string{"Beta"}}, plugin.BackgroundWriteOptions{RequestID: "project-assign-second"}); err != nil {
		panic(err)
	}
	if _, err := projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "merge", Names: []string{"Beta"}, Target: "First", Emoji: stringPointer("🏷️")}, plugin.BackgroundWriteOptions{RequestID: "project-merge"}); err != nil {
		panic(err)
	}
	assertThreadTags(r, secondRef.ThreadID, "First")
	assertTagEmoji(r, secondRef.ThreadID, "First", "🏷️")
	if _, err := projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "delete", Name: "First"}, plugin.BackgroundWriteOptions{RequestID: "project-delete-used"}); err == nil {
		panic("in-use tag deletion accepted")
	}
	if _, err := projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "delete", Name: "Gamma"}, plugin.BackgroundWriteOptions{RequestID: "project-delete-unused"}); err != nil {
		panic(err)
	}
	if _, err := projectWrite.Execute(ctx, plugin.SemanticTagOperation{Kind: "create", Name: "Gamma", Emoji: stringPointer("🔧")}, plugin.BackgroundWriteOptions{RequestID: "project-reuse"}); err != nil {
		panic(err)
	}

	pool, err := projectRead.CaptureList(ctx)
	must(err)
	for _, tag := range pool {
		if tag.Emoji == "" || tag.Emoji == "invalid" {
			panic("pool exposed missing or invalid emoji")
		}
	}
	if len(pool) != 4 {
		panic("unexpected scoped pool size")
	}
	usage, err := projectRead.CaptureUsage(ctx, "First")
	must(err)
	if len(usage.Threads) != 2 {
		panic("scoped tag usage did not include both threads")
	}
	inboxPool, err := inboxRead.CaptureList(ctx)
	must(err)
	if len(inboxPool) != 1 || inboxPool[0].Name != "Investigation" {
		panic("inbox pool was contaminated by another scope")
	}

	// Lifecycle routing must deliver each scope's events only to its own agent.
	projectConsumer := scopedLifecycleConsumer(r, scope, "tag.agent.verify-project-events", "scope-events")
	projectEvents, err := projectConsumer.Pending(plugin.PendingEventsQuery{})
	must(err)
	if len(projectEvents) < 2 {
		panic("directory scope did not receive its thread events")
	}
	for _, event := range projectEvents {
		if event.Scope != scope {
			panic("directory scope received another scope's event")
		}
	}
	inboxConsumer := scopedLifecycleConsumer(r, directorytag.InboxScope, "tag.agent.verify-inbox-events", "inbox-events")
	inboxEvents, err := inboxConsumer.Pending(plugin.PendingEventsQuery{})
	must(err)
	if len(inboxEvents) == 0 {
		panic("inbox scope received no thread events")
	}
	for _, event := range inboxEvents {
		if event.Scope != directorytag.InboxScope {
			panic("inbox scope received a directory event")
		}
	}
}

func scopedLifecycleConsumer(r *core.Runtime, scope, agentID, consumerID string) plugin.LifecycleConsumer {
	capabilities := r.BackgroundCapabilities(plugin.BackgroundAgentRef{PluginID: "tag", AgentID: agentID, Binding: plugin.ScopeBinding{Kind: plugin.DirectoryScopeKind, Scope: scope}, ScopeLabel: "verification"}, "tag.settings")
	lifecycle, err := plugin.Require[plugin.LifecycleCapability](capabilities, plugin.LifecycleCapabilityKey)
	must(err)
	consumer, err := lifecycle.Register(plugin.LifecycleConsumerDefinition{ID: consumerID, Filter: plugin.LifecycleScope{{
		SubjectKinds: []string{"thread"}, SubjectTypeIDs: []string{"agent"},
		Types: []string{"thread.input-accepted"},
	}}})
	must(err)
	return consumer
}

func scopedTagCapabilities(r *core.Runtime, scope, agentID string) (plugin.SemanticTagsReadCapability, plugin.SemanticTagsWriteCapability) {
	capabilities := r.BackgroundCapabilities(plugin.BackgroundAgentRef{PluginID: "tag", AgentID: agentID, Binding: plugin.ScopeBinding{Kind: plugin.DirectoryScopeKind, Scope: scope}, ScopeLabel: "verification"}, "tag.settings")
	read, err := plugin.Require[plugin.SemanticTagsReadCapability](capabilities, plugin.SemanticTagsReadCapabilityKey)
	must(err)
	write, err := plugin.Require[plugin.SemanticTagsWriteCapability](capabilities, plugin.SemanticTagsWriteCapabilityKey)
	must(err)
	return read, write
}

func assertThreadTags(r *core.Runtime, id, want string) {
	thread, err := r.Thread(id)
	must(err)
	if len(thread.Tags) != 1 || thread.Tags[0] != want {
		panic("scoped tag assignment missing")
	}
}

func stringPointer(value string) *string { return &value }
func assertTagEmoji(r *core.Runtime, id, name, emoji string) {
	thread, err := r.Thread(id)
	must(err)
	wire := raw(thread)
	var envelope struct {
		TagEmojis map[string]string `json:"tagEmojis"`
	}
	must(json.Unmarshal(wire, &envelope))
	if envelope.TagEmojis[name] != emoji {
		panic(fmt.Sprintf("tag emoji wire mismatch: %s", wire))
	}
}

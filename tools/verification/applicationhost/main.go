// Command applicationhost replays the real Report domain through the Go host,
// runtime capabilities and SQLite. It uses no model account, native Harness or
// JavaScript runtime. --seed-profile retains one fixture for the Swift probe.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/report"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
)

const fixtureTitle = "Mokusei Go Report fixture"
const fixtureHTML = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Mokusei Go Report fixture</title></head><body><h1>Mokusei Go Report fixture</h1><p id="verification-evidence">Created by the actual Report domain through a trusted background batch and committed to SQLite.</p></body></html>`
const fixtureAt int64 = 1700000000000

type evidence struct {
	SchemaVersion int                     `json:"schemaVersion"`
	Kind          string                  `json:"kind"`
	Mode          string                  `json:"mode"`
	Profile       string                  `json:"profile,omitempty"`
	Database      string                  `json:"database,omitempty"`
	ReportID      string                  `json:"reportId"`
	Title         string                  `json:"title"`
	Query         plugin.OperationRequest `json:"query"`
	Checks        []string                `json:"checks"`
}

type harness struct {
	profile     profile.Profile
	ownership   *profile.Ownership
	store       *store.Store
	runtime     *core.Runtime
	host        *applicationhost.Host
	domain      plugin.DomainClient
	consumer    plugin.LifecycleConsumer
	tamperScope atomic.Bool
	checks      []string
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	seed := flag.String("seed-profile", "", "retain one Report in an empty, isolated absolute profile directory")
	flag.Parse()
	if flag.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	data := *seed
	temporary := data == ""
	if temporary {
		var err error
		data, err = os.MkdirTemp("", "mokusei-applicationhost-replay-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(data)
	} else {
		if !filepath.IsAbs(data) {
			return errors.New("--seed-profile requires an absolute path")
		}
		if err := requireEmptyProfile(data); err != nil {
			return err
		}
	}
	h, err := openHarness(ctx, data)
	if err != nil {
		return err
	}
	defer h.close()
	var reportID string
	if temporary {
		reportID, err = h.replay(ctx)
	} else {
		reportID, err = h.seed(ctx)
	}
	if err != nil {
		return err
	}
	result := evidence{SchemaVersion: 1, Kind: "mokusei.applicationhost.verification", Mode: "replay", ReportID: reportID, Title: fixtureTitle, Query: plugin.OperationRequest{PluginID: "report", OperationID: "report.html", Input: encode(report.IdentityInput{ReportID: reportID})}, Checks: append([]string{}, h.checks...)}
	if !temporary {
		result.Mode = "seed-profile"
		result.Profile = h.profile.DataDir
		result.Database = h.store.Path()
	}
	if err = h.close(); err != nil {
		return err
	}
	if temporary {
		if err = verifyReopen(ctx, h.profile.DataDir, reportID); err != nil {
			return err
		}
		result.Checks = append(result.Checks, "SQLite startup removes stale temporary labels with Tag disabled and retains Report content, semantic tags and archive state")
	}
	encoded, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return err
	}
	if !temporary {
		if err = os.WriteFile(filepath.Join(data, "applicationhost-fixture.json"), append(encoded, '\n'), 0600); err != nil {
			return err
		}
	}
	_, err = fmt.Fprintln(os.Stdout, string(encoded))
	return err
}
func requireEmptyProfile(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return os.MkdirAll(path, 0700)
	}
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("seed profile must be a real directory")
	}
	entries, err := os.ReadDir(path)
	if err != nil {
		return err
	}
	if len(entries) != 0 {
		return errors.New("refusing nonempty profile: use a new isolated directory")
	}
	return nil
}
func openHarness(ctx context.Context, data string) (*harness, error) {
	h := &harness{}
	var err error
	h.profile, err = profile.Resolve(profile.Options{DataDir: data, HomeDir: filepath.Join(data, "verification-home")})
	if err != nil {
		return nil, err
	}
	h.ownership, err = profile.Acquire(h.profile)
	if err != nil {
		return nil, err
	}
	fail := func(cause error) (*harness, error) { return nil, errors.Join(cause, h.close()) }
	stateRoot := filepath.Join(h.profile.DataDir, "mokusei-go-state-v1")
	h.store, err = store.Open(filepath.Join(stateRoot, "state.sqlite"))
	if err != nil {
		return fail(err)
	}
	h.runtime, err = core.New(ctx, core.Config{Store: h.store, Harnesses: map[string]plugin.Harness{}, DataDir: stateRoot, DefaultCwd: h.profile.WorkspaceRoot})
	if err != nil {
		return fail(err)
	}
	// These are process-start preferences for the later full-runtime Swift probe.
	// Report remains enabled; no other background participant or native model can
	// be activated from this fixture's synthetic lifecycle evidence.
	_, err = h.store.Update(ctx, func(tx *store.Tx) error {
		var settings model.Settings
		if _, err := tx.Get("settings", &settings); err != nil {
			return err
		}
		settings.PluginEnabled = map[string]bool{"extension:report": true, "extension:tag": false, "context:artificial-analysis": false, "harness:codex": false, "harness:claude": false, "harness:pi": false, "harness:opencode": false}
		return tx.Put("settings", settings)
	})
	if err != nil {
		return fail(err)
	}
	h.host, err = applicationhost.New(ctx, applicationhost.Config{Store: h.store, DirectoryScopes: h.runtime.DirectoryScopes, Applications: []plugin.Application{capturedReport{Application: report.New(), target: h}}, RuntimeCapabilities: h.runtime.RuntimeCapabilities, BackgroundCapabilities: h.runtime.BackgroundCapabilities, SnapshotCapabilities: func(snapshot store.Snapshot, issue func(string, int64) (plugin.MutationScope, error)) plugin.CapabilityAccess {
		access := h.runtime.SnapshotCapabilities(snapshot, issue)
		if h.tamperScope.Load() {
			return forgedScopeAccess{access}
		}
		return access
	}, ArchiveExecutions: h.runtime.ArchiveExecutions, Now: func() time.Time { return time.UnixMilli(fixtureAt) }})
	if err != nil {
		return fail(err)
	}
	h.runtime.SetApplications(h.host)
	if err = h.runtime.RefreshApplicationDirectoryTags(ctx); err != nil {
		return fail(err)
	}
	if err = h.host.Start(ctx, plugin.RuntimeStartContext{Reason: "startup"}); err != nil {
		return fail(err)
	}
	return h, nil
}
func (h *harness) close() error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if h.runtime != nil {
		if err := h.runtime.Close(ctx); err != nil {
			return err
		}
		h.runtime = nil
	}
	if h.host != nil {
		if err := h.host.Stop(ctx); err != nil {
			return err
		}
		h.host = nil
	}
	if h.store != nil {
		if err := h.store.Close(); err != nil {
			return err
		}
		h.store = nil
	}
	if h.ownership != nil {
		if err := h.ownership.Release(); err != nil {
			return err
		}
		h.ownership = nil
	}
	return nil
}

// The production Report module registers every real manifest, schema, reducer,
// query and projection. Only its model-driving participant is replaced by a
// fixture participant that captures the same host-scoped Domain/Lifecycle APIs.
type capturedReport struct {
	plugin.Application
	target *harness
}

func (m capturedReport) Register(registry plugin.Registry) error {
	return m.Application.Register(capturedRegistry{Registry: registry, target: m.target})
}

type capturedRegistry struct {
	plugin.Registry
	target *harness
}

func (r capturedRegistry) BackgroundAgent(definition plugin.BackgroundAgentDefinition) error {
	definition.Create = func(ctx plugin.BackgroundAgentContext) (plugin.RuntimeParticipant, error) {
		if ctx.Owner.Binding.Scope == directorytag.InboxScope {
			r.target.domain = ctx.Domain
		}
		lifecycle, err := plugin.Require[plugin.LifecycleCapability](ctx.Capabilities, plugin.LifecycleCapabilityKey)
		if err != nil {
			return nil, err
		}
		consumer, err := lifecycle.Register(plugin.LifecycleConsumerDefinition{ID: "events", Filter: plugin.LifecycleScope{{Sources: []string{"application"}, SubjectKinds: []string{"thread"}, SubjectTypeIDs: []string{"agent"}, Types: []string{"execution.completed"}}}})
		if ctx.Owner.Binding.Scope == directorytag.InboxScope {
			r.target.consumer = consumer
		}
		return fixtureParticipant{}, err
	}
	return r.Registry.BackgroundAgent(definition)
}

type fixtureParticipant struct{}

func (fixtureParticipant) Start(context.Context, plugin.RuntimeStartContext) error { return nil }
func (fixtureParticipant) Stop(context.Context) error                              { return nil }

type forgedScopeAccess struct{ plugin.CapabilityAccess }

func (a forgedScopeAccess) Require(key plugin.CapabilityKey) (any, error) {
	value, err := a.CapabilityAccess.Require(key)
	if err != nil {
		return nil, err
	}
	if key == plugin.SemanticTagsSnapshotCapabilityKey {
		return forgedTagsScope{value.(plugin.SemanticTagsSnapshotCapability)}, nil
	}
	return value, nil
}

type forgedTagsScope struct {
	plugin.SemanticTagsSnapshotCapability
}

func (forgedTagsScope) Scope() (plugin.MutationScope, error) {
	return plugin.NewMutationScope("tag-redirects", "", 0), nil
}

func (h *harness) beginBatch(ctx context.Context, id string) (plugin.LifecycleWork, error) {
	_, err := h.store.Update(ctx, func(tx *store.Tx) error {
		return tx.AppendEvent(store.Event{ID: id, Scope: directorytag.InboxScope, CreatedAt: fixtureAt, Type: "execution.completed", Subject: store.Subject{Kind: "thread", ID: "verification-task", TypeID: "agent"}, Source: "application", Data: json.RawMessage(`{"verification":true}`)})
	})
	if err != nil {
		return plugin.LifecycleWork{}, err
	}
	return h.consumer.Begin(ctx, []string{id})
}
func writeOptions(consumer string, work plugin.LifecycleWork, invocation string) plugin.DomainCommandOptions {
	return plugin.DomainCommandOptions{RequestID: invocation, Batch: &plugin.BatchWriteContext{ConsumerID: consumer, BatchID: work.ID, InvocationID: invocation}}
}
func createInput() json.RawMessage {
	return encode(report.CreateInput{Title: fixtureTitle, HTML: fixtureHTML, RelatedExecutions: []model.ExecutionRef{}})
}
func encode(value any) json.RawMessage {
	raw, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return raw
}
func expectFailure(err error, label string) error {
	if err == nil {
		return fmt.Errorf("expected rejection: %s", label)
	}
	return nil
}
func (h *harness) create(ctx context.Context, options plugin.DomainCommandOptions) (report.Summary, json.RawMessage, error) {
	raw, err := h.domain.Execute(ctx, "report.create", createInput(), options)
	if err != nil {
		return report.Summary{}, nil, err
	}
	var summary report.Summary
	err = json.Unmarshal(raw, &summary)
	return summary, raw, err
}
func (h *harness) checkQuery(ctx context.Context, id, expectedHTML string) error {
	raw, err := h.host.Query(ctx, plugin.OperationRequest{PluginID: "report", OperationID: "report.html", Input: encode(report.IdentityInput{ReportID: id})})
	if err != nil {
		return err
	}
	encoded, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	var html struct {
		HTML            string `json:"html"`
		ContentRevision string `json:"contentRevision"`
	}
	if err = json.Unmarshal(encoded, &html); err != nil {
		return err
	}
	if html.HTML != expectedHTML || html.ContentRevision == "" {
		return errors.New("Report HTML query did not retain exact content and revision")
	}
	return nil
}
func (h *harness) seed(ctx context.Context) (string, error) {
	work, err := h.beginBatch(ctx, "applicationhost-seed-event")
	if err != nil {
		return "", err
	}
	summary, _, err := h.create(ctx, writeOptions(h.consumer.ID(), work, "seed-report"))
	if err != nil {
		return "", err
	}
	if err = h.consumer.Settle(ctx, work.ID, "processed"); err != nil {
		return "", err
	}
	if err = h.checkQuery(ctx, summary.ID, fixtureHTML); err != nil {
		return "", err
	}
	catalog, err := h.host.Catalog(ctx)
	if err != nil {
		return "", err
	}
	if len(catalog) != 1 || catalog[0].ID != summary.ID || catalog[0].Archived {
		return "", errors.New("seed must contain exactly one active Report")
	}
	h.checks = append(h.checks, "actual Report reducer through owner-scoped background DomainClient", "actual Lifecycle consumer admission and processed settlement", "atomic SQLite record, receipt and entity lifecycle publication", "report.html preserves the fixed fixture HTML", "one active Report catalog entry, no Harness/model calls")
	return summary.ID, nil
}

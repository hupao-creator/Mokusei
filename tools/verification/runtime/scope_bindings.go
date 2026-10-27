package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
	"github.com/hupao-creator/Mokusei/internal/services/workspaces"
)

// An unrelated plugin declares both policies without naming scope IDs or
// supplying any event scope filter. It exercises the host/capability contract,
// independently of Report/Tag domain policy and native resource policy.
type bindingProbe struct {
	policy    plugin.InstancePolicy
	mu        sync.Mutex
	instances map[string]*bindingProbeInstance
	created   int
}
type bindingProbeInstance struct {
	owner     plugin.BackgroundAgentRef
	lifecycle plugin.LifecycleCapability
	consumer  plugin.LifecycleConsumer
	tasks     plugin.OrdinaryTaskReadCapability
}

func (*bindingProbe) Manifest() plugin.ApplicationManifest {
	return plugin.ApplicationManifest{ID: "range-probe", DisplayName: "Range Probe", APIVersion: 1,
		Contributes: plugin.Contributions{BackgroundAgents: []string{"range-probe.global", "range-probe.directory"}}}
}
func (p *bindingProbe) Register(registry plugin.Registry) error {
	for _, def := range []struct {
		id     string
		policy plugin.InstancePolicy
	}{{"range-probe.global", plugin.GlobalInstance}, {"range-probe.directory", p.policy}} {
		err := registry.BackgroundAgent(plugin.BackgroundAgentDefinition{ID: def.id, InstancePolicy: def.policy,
			Requires: []plugin.CapabilityKey{plugin.LifecycleCapabilityKey, plugin.OrdinaryTaskReadCapabilityKey},
			Create: func(ctx plugin.BackgroundAgentContext) (plugin.RuntimeParticipant, error) {
				lifecycle, err := plugin.Require[plugin.LifecycleCapability](ctx.Capabilities, plugin.LifecycleCapabilityKey)
				if err != nil {
					return nil, err
				}
				tasks, err := plugin.Require[plugin.OrdinaryTaskReadCapability](ctx.Capabilities, plugin.OrdinaryTaskReadCapabilityKey)
				if err != nil {
					return nil, err
				}
				consumer, err := lifecycle.Register(plugin.LifecycleConsumerDefinition{ID: "events",
					Filter:  plugin.LifecycleScope{{Sources: []string{"application", "user"}, SubjectTypeIDs: []string{"agent"}, Types: []string{"thread.input-accepted"}}},
					History: plugin.LifecycleScope{{}}})
				if err != nil {
					return nil, err
				}
				p.mu.Lock()
				p.instances[ctx.Owner.AgentID] = &bindingProbeInstance{ctx.Owner, lifecycle, consumer, tasks}
				p.created++
				p.mu.Unlock()
				return probeParticipant{}, nil
			}})
		if err != nil {
			return err
		}
	}
	return nil
}

type probeParticipant struct{}

func (probeParticipant) Start(context.Context, plugin.RuntimeStartContext) error { return nil }
func (probeParticipant) Stop(context.Context) error                              { return nil }
func (p *bindingProbe) instance(binding plugin.ScopeBinding) *bindingProbeInstance {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, instance := range p.instances {
		if instance.owner.Binding == binding {
			return instance
		}
	}
	panic("missing declared background instance")
}

func verifyBackgroundScopeBindings(ctx context.Context) {
	if directorytag.Scope(string(filepath.Separator)) != string(filepath.Separator) {
		panic("filesystem root was folded into Inbox")
	}
	for _, names := range [][2]string{{"a", "b"}, {"a", "a "}, {`repo\branch`, "repo/branch"}, {`runtime-workspace\tmp-workspaces`, "b"}} {
		verifyBackgroundScopeBindingPaths(ctx, names[0], names[1])
	}
}

func verifyBackgroundScopeBindingPaths(ctx context.Context, aName, bName string) {
	data, err := os.MkdirTemp("", "mokusei-instance-bindings-")
	must(err)
	defer os.RemoveAll(data)
	projects, err := os.MkdirTemp("/tmp", "scope-binding-projects-")
	must(err)
	defer os.RemoveAll(projects)
	aDir, bDir := filepath.Join(projects, aName), filepath.Join(projects, bName)
	must(os.MkdirAll(aDir, 0700))
	must(os.MkdirAll(bDir, 0700))
	aScope, bScope := directorytag.Scope(aDir), directorytag.Scope(bDir)
	if aScope == bScope || aScope == directorytag.InboxScope || bScope == directorytag.InboxScope {
		panic(fmt.Sprintf("distinct physical directories share authority: %q => %q, %q => %q", aDir, aScope, bDir, bScope))
	}
	globalBinding := plugin.ScopeBinding{Kind: plugin.GlobalScope}
	aBinding := plugin.ScopeBinding{Kind: plugin.DirectoryScopeKind, Scope: aScope}
	bBinding := plugin.ScopeBinding{Kind: plugin.DirectoryScopeKind, Scope: bScope}
	inboxBinding := plugin.ScopeBinding{Kind: plugin.DirectoryScopeKind, Scope: "inbox"}
	var db *store.Store
	var runtime *core.Runtime
	var host *applicationhost.Host
	var probe *bindingProbe
	open := func() {
		db, err = store.Open(filepath.Join(data, "state.sqlite"))
		must(err)
		runtime, err = core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": harness{}}, DataDir: data, DefaultCwd: data,
			Workspaces: workspaces.New(workspaces.Paths{DefaultCwd: data, TemporaryRoot: filepath.Join(data, "tmp-workspaces"), RegistryPath: filepath.Join(data, "worktrees.json")})})
		must(err)
		probe = &bindingProbe{policy: plugin.PerDirectoryScope, instances: map[string]*bindingProbeInstance{}}
		host, err = applicationhost.New(ctx, applicationhost.Config{Store: db, Applications: []plugin.Application{probe}, DirectoryScopes: runtime.DirectoryScopes,
			RuntimeCapabilities: runtime.RuntimeCapabilities, BackgroundCapabilities: runtime.BackgroundCapabilities, SnapshotCapabilities: runtime.SnapshotCapabilities})
		must(err)
		runtime.SetApplications(host)
	}
	open()
	defer func() { must(runtime.Close(ctx)); must(db.Close()) }()
	// Reject a missing instance policy at registration, before starting anything.
	_, err = applicationhost.New(ctx, applicationhost.Config{Store: db, Applications: []plugin.Application{&bindingProbe{}}})
	expectReportDenied(err, "missing instance policy")
	for _, binding := range []plugin.ScopeBinding{{}, {Kind: "unknown"}, {Kind: plugin.DirectoryScopeKind}, {Kind: plugin.DirectoryScopeKind, Scope: "relative"}, {Kind: plugin.GlobalScope, Scope: "inbox"}} {
		caps := runtime.BackgroundCapabilities(plugin.BackgroundAgentRef{PluginID: "range-probe", AgentID: "invalid", Binding: binding}, "")
		for _, key := range []plugin.CapabilityKey{plugin.LifecycleCapabilityKey, plugin.OrdinaryTaskReadCapabilityKey, plugin.BackgroundSessionsCapabilityKey} {
			_, err := caps.Require(key)
			expectReportDenied(err, "invalid scope binding")
		}
	}
	must(host.Start(ctx, plugin.RuntimeStartContext{Reason: "startup"}))
	if len(host.BackgroundInstances()) != 2 {
		panic("startup requires one global and one Inbox instance")
	}
	input := model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "scope binding evidence"}}}
	a, err := runtime.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Cwd: aDir, Input: input})
	must(err)
	b, err := runtime.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Cwd: bDir, Input: input})
	must(err)
	inbox, err := runtime.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Input: input})
	must(err)
	must(host.RefreshScopeAgents(ctx))
	if len(host.BackgroundInstances()) != 4 || probe.created != 4 {
		panic("dynamic scope refresh duplicated global or scoped instances")
	}
	aInstance, bInstance := probe.instance(aBinding), probe.instance(bBinding)
	global, inboxInstance := probe.instance(globalBinding), probe.instance(inboxBinding)
	for _, entry := range []struct {
		instance *bindingProbeInstance
		ids      []string
	}{{aInstance, []string{a.Record.ID}}, {bInstance, []string{b.Record.ID}}, {inboxInstance, []string{inbox.Record.ID}}, {global, []string{a.Record.ID, b.Record.ID, inbox.Record.ID}}} {
		tasks, err := entry.instance.tasks.CaptureList(ctx, true)
		must(err)
		if len(tasks) != len(entry.ids) {
			panic("task list escaped explicit instance authority")
		}
		for _, task := range tasks {
			if !containsString(entry.ids, task.Ref.ThreadID) {
				panic("foreign task in bound list")
			}
		}
		pending, err := entry.instance.consumer.Pending(plugin.PendingEventsQuery{})
		must(err)
		if len(pending) != len(entry.ids) {
			panic("delivery did not intersect omitted plugin scope")
		}
		for _, event := range pending {
			if !entry.instance.owner.Binding.Allows(event.Scope) || event.Type != "thread.input-accepted" {
				panic("delivery broadened plugin or instance scope")
			}
		}
	}
	aPending, err := aInstance.consumer.Pending(plugin.PendingEventsQuery{})
	must(err)
	bPending, err := bInstance.consumer.Pending(plugin.PendingEventsQuery{})
	must(err)
	page, err := aInstance.consumer.Read(plugin.LifecycleHistoryQuery{PageRequest: plugin.PageRequest{Limit: 100}, EventIDs: []string{aPending[0].ID, bPending[0].ID}})
	must(err)
	if len(page.Items) != 1 || page.Items[0].ID != aPending[0].ID {
		panic("explicit history IDs bypassed binding")
	}
	foreign, err := aInstance.lifecycle.Register(plugin.LifecycleConsumerDefinition{ID: "foreign", Filter: plugin.LifecycleScope{{Scope: bScope}}})
	must(err)
	foreignPending, err := foreign.Pending(plugin.PendingEventsQuery{})
	must(err)
	foreignHistory, err := foreign.Read(plugin.LifecycleHistoryQuery{PageRequest: plugin.PageRequest{Limit: 100}})
	must(err)
	if len(foreignPending) != 0 || len(foreignHistory.Items) != 0 {
		panic("foreign rule was broadened instead of intersected")
	}
	_, err = aInstance.consumer.Begin(ctx, []string{bPending[0].ID})
	expectReportDenied(err, "foreign batch admission")
	_, err = aInstance.consumer.Subscribe(ctx, func(plugin.LifecycleNotification) {}, &plugin.PrivateSessionRef{Owner: bInstance.owner, SessionKey: "primary", SessionID: "foreign"})
	expectReportDenied(err, "foreign session observation")
	observed := make(chan plugin.LifecycleEvent, 128)
	unsubscribe, err := aInstance.lifecycle.Subscribe(ctx, plugin.LifecycleScope{{}}, func(event plugin.LifecycleEvent) { observed <- event })
	must(err)
	notifications := make(chan plugin.LifecycleNotification, 128)
	unwatch, err := aInstance.consumer.Subscribe(ctx, func(n plugin.LifecycleNotification) { notifications <- n }, nil)
	must(err)
	_, err = runtime.SendThread(ctx, b.Record.ID, input)
	must(err)
	_, err = runtime.SendThread(ctx, inbox.Record.ID, input)
	must(err)
	_, err = runtime.SendThread(ctx, a.Record.ID, input)
	must(err)
	// The own event is appended last. Seeing it proves the subscription has
	// processed a snapshot that also contains the foreign events.
	seenOwn := false
	waitFor(func() bool {
		for {
			select {
			case event := <-observed:
				if event.Scope != aScope {
					panic("direct subscription leaked scope")
				}
				if event.Type == "thread.input-accepted" {
					seenOwn = true
				}
			default:
				return seenOwn
			}
		}
	})
	waitFor(func() bool {
		for {
			select {
			case n := <-notifications:
				for _, event := range n.Pending {
					if event.Scope != aScope {
						panic("consumer notification leaked scope")
					}
				}
				if len(n.Pending) == 2 {
					return true
				}
			default:
				return false
			}
		}
	})
	unsubscribe()
	unwatch()
	work, err := aInstance.consumer.Begin(ctx, []string{aPending[0].ID})
	must(err)
	identity := aInstance.owner.AgentID
	must(runtime.DeleteThread(ctx, a.Record.ID))
	must(runtime.Close(ctx))
	must(db.Close())
	open()
	must(host.Start(ctx, plugin.RuntimeStartContext{Reason: "restart"}))
	aInstance = probe.instance(aBinding)
	if aInstance.owner.AgentID != identity || aInstance.consumer.Work() == nil || aInstance.consumer.Work().ID != work.ID {
		panic("source deletion lost durable instance/work identity")
	}
	// No completed event ever existed in this directory: recovery must use the
	// durable directory catalog, independently of Report trigger policy.
	scopes, err := runtime.DirectoryScopes()
	must(err)
	if len(scopes) != 3 {
		panic("deleted source removed generic directory identity")
	}
	must(aInstance.consumer.Settle(ctx, work.ID, "processed"))
	must(runtime.ClearHistory(ctx))
	scopes, err = runtime.DirectoryScopes()
	must(err)
	if len(scopes) != 1 || scopes[0].ID != "inbox" || len(host.BackgroundInstances()) != 2 {
		panic("history reset retained stale directory instances")
	}
	fmt.Println("PASS declarative global/directory instances, automatic event/history/task bounds, Inbox and invalid bindings, dynamic discovery, subscription isolation and source-deleted durable recovery")
}
func containsString(values []string, value string) bool {
	for _, item := range values {
		if item == value {
			return true
		}
	}
	return false
}

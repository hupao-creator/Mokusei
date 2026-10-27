package main

import (
	"context"
	"fmt"
	"path/filepath"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

func verifyLifecycleSubscriptions(ctx context.Context, root string) {
	data := filepath.Join(root, "lifecycle-subscriptions")
	db, err := store.Open(filepath.Join(data, "state.sqlite"))
	must(err)
	runtime, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": harness{}}, DataDir: data, DefaultCwd: data})
	must(err)
	defer func() { must(runtime.Close(ctx)); must(db.Close()) }()
	owner := plugin.BackgroundAgentRef{PluginID: "subscription-probe", AgentID: "subscription-probe.agent", Binding: plugin.ScopeBinding{Kind: plugin.GlobalScope}}
	caps := runtime.BackgroundCapabilities(owner, "")
	lifecycle, err := plugin.Require[plugin.LifecycleCapability](caps, plugin.LifecycleCapabilityKey)
	must(err)
	configuration, err := plugin.Require[plugin.BackgroundConfigurationCapability](caps, plugin.BackgroundConfigurationCapabilityKey)
	must(err)
	sessions, err := plugin.Require[plugin.BackgroundSessionsCapability](caps, plugin.BackgroundSessionsCapabilityKey)
	must(err)
	resolved, err := configuration.Resolve(ctx, "primary")
	must(err)
	configured, err := sessions.Configure(ctx, plugin.ConfigureSessionRequest{SessionKey: "primary", Configuration: resolved})
	must(err)
	privateKey := ""
	for _, key := range db.Snapshot().Keys("private-session:") {
		var candidate plugin.PrivateSessionSnapshot
		_, err := db.Snapshot().Get(key, &candidate)
		must(err)
		if candidate.Ref == configured.Ref {
			privateKey = key
		}
	}
	if privateKey == "" {
		panic("configured observation fixture is missing")
	}
	appendFact := func(id string, at int64) {
		_, err := db.Update(ctx, func(tx *store.Tx) error {
			return tx.AppendEvent(store.Event{ID: id, CreatedAt: at, Type: "thread.input-accepted", Source: "user",
				Subject: store.Subject{Kind: "thread", ID: "subscription-task", TypeID: "agent"}, Data: raw(map[string]any{})})
		})
		must(err)
	}
	appendFact("before-subscription", 1)
	live := make(chan plugin.LifecycleEvent, 16)
	stopLive, err := runtime.SubscribeUserThreadInputs(ctx, func(event plugin.LifecycleEvent) { live <- event })
	must(err)
	defer stopLive()
	// Commit immediately after registration, before waiting for the goroutine.
	// The old event must stay suppressed and the new one must not fall in a gap.
	appendFact("after-subscription", 2)
	if event := receiveLifecycleFixture(ctx, live); event.ID != "after-subscription" {
		panic("live subscription replayed history or missed registration boundary")
	}
	consumer, err := lifecycle.Register(plugin.LifecycleConsumerDefinition{ID: "facts",
		Filter: plugin.LifecycleScope{{Sources: []string{"user"}, Types: []string{"thread.input-accepted"}}}})
	must(err)
	notifications := make(chan plugin.LifecycleNotification, 16)
	subscriptionCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	stopConsumer, err := consumer.Subscribe(subscriptionCtx, func(value plugin.LifecycleNotification) { notifications <- value }, &configured.Ref)
	must(err)
	defer stopConsumer()
	initial := receiveLifecycleFixture(ctx, notifications)
	if len(initial.Pending) != 2 || initial.Work != nil || initial.Observation == nil || initial.Observation.LatestExecution != nil {
		panic("durable subscription initial snapshot changed")
	}
	_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("unrelated-subscription-fixture", 1) })
	must(err)
	quietLifecycleFixture(live, "live subscription repeated an existing fact")
	quietLifecycleFixture(notifications, "durable subscription repeated an unchanged notification")
	work, err := consumer.Begin(ctx, []string{"before-subscription"})
	must(err)
	started := receiveLifecycleFixture(ctx, notifications)
	if started.Work == nil || started.Work.ID != work.ID || len(started.Pending) != 2 {
		panic("work-only admission did not notify its consumer")
	}
	must(consumer.Update(ctx, plugin.LifecycleWorkUpdate{ID: work.ID, EventIDs: work.EventIDs, Attempts: 2, NextAttemptAt: 50, ExecutionID: "private-execution"}))
	updated := receiveLifecycleFixture(ctx, notifications)
	if updated.Work == nil || updated.Work.Attempts != 2 || updated.Work.NextAttemptAt != 50 || updated.Work.ExecutionID != "private-execution" {
		panic("work-only update did not notify its consumer")
	}
	must(consumer.Settle(ctx, work.ID, "processed"))
	settled := receiveLifecycleFixture(ctx, notifications)
	if settled.Work != nil || len(settled.Pending) != 1 || settled.Pending[0].ID != "after-subscription" {
		panic("work settlement did not publish the durable outcome")
	}
	quietLifecycleFixture(live, "work updates were replayed as live events")
	// The fixture changes only a private record, deliberately without appending
	// an event. Observation delivery must have an independent invalidation source.
	writeSession := func(session plugin.PrivateSessionSnapshot) {
		eventCount := len(db.Snapshot().Keys("event:"))
		_, err := db.Update(ctx, func(tx *store.Tx) error { return tx.Put(privateKey, session) })
		must(err)
		if len(db.Snapshot().Keys("event:")) != eventCount {
			panic("private observation fixture unexpectedly appended a lifecycle event")
		}
	}
	finished := int64(20)
	configured.Record.Revision++
	configured.Record.Observation.LatestExecution = &model.PublicExecution{ExecutionID: "observed-execution", Status: "completed", StartedAt: 10, FinishedAt: &finished}
	writeSession(configured)
	observed := receiveLifecycleFixture(ctx, notifications)
	if observed.Observation == nil || observed.Observation.LatestExecution == nil || observed.Observation.LatestExecution.ExecutionID != "observed-execution" {
		panic("private observation without a lifecycle event was skipped")
	}
	replacement := configured
	replacement.Ref.SessionID = "replacement-session"
	replacement.Record.ID = replacement.Ref.SessionID
	writeSession(replacement)
	if replaced := receiveLifecycleFixture(ctx, notifications); replaced.Observation != nil {
		panic("subscription observed a replacement private session incarnation")
	}
	writeSession(configured)
	if restored := receiveLifecycleFixture(ctx, notifications); restored.Observation == nil {
		panic("restored private session identity was skipped")
	}
	quietLifecycleFixture(notifications, "private observation was repeated")
	stopLive()
	cancel()
	stopConsumer()

	// Hold the callback while multiple commits collapse into the Store's bounded
	// revision channel. The next callback must describe the latest durable inbox.
	slow := make(chan plugin.LifecycleNotification, 16)
	entered, release := make(chan struct{}), make(chan struct{})
	slowCtx, cancelSlow := context.WithCancel(ctx)
	defer cancelSlow()
	first := true
	stopSlow, err := consumer.Subscribe(slowCtx, func(value plugin.LifecycleNotification) {
		if first {
			first = false
			close(entered)
			select {
			case <-release:
			case <-slowCtx.Done():
				return
			}
		}
		slow <- value
	}, nil)
	must(err)
	defer stopSlow()
	receiveLifecycleFixture(ctx, entered)
	appendFact("coalesced-one", 3)
	appendFact("coalesced-two", 4)
	_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("unrelated-subscription-fixture", 2) })
	must(err)
	close(release)
	if before := receiveLifecycleFixture(ctx, slow); len(before.Pending) != 1 {
		panic("blocked subscriber did not retain its captured notification")
	}
	after := receiveLifecycleFixture(ctx, slow)
	if len(after.Pending) != 3 || after.Pending[1].ID != "coalesced-one" || after.Pending[2].ID != "coalesced-two" {
		panic("coalesced subscription notifications lost durable facts")
	}
	quietLifecycleFixture(live, "released live subscription received a new event")
	quietLifecycleFixture(notifications, "cancelled durable subscription received a new notification")
}

func receiveLifecycleFixture[T any](ctx context.Context, values <-chan T) T {
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case value := <-values:
		return value
	case <-ctx.Done():
		panic(ctx.Err())
	case <-timer.C:
		panic("lifecycle subscription fixture deadline")
	}
}

func quietLifecycleFixture[T any](values <-chan T, message string) {
	timer := time.NewTimer(50 * time.Millisecond)
	defer timer.Stop()
	select {
	case value := <-values:
		panic(fmt.Sprintf("%s: %+v", message, value))
	case <-timer.C:
	}
}

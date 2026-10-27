package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

// verifyOverview replays transient presentation control through the public
// broker boundary. Request delivery, rather than sleeps, orders each scenario.
func verifyOverview(ctx context.Context) error {
	for _, scenario := range []struct {
		name string
		run  func(context.Context) error
	}{
		{"read isolation and wire validation", overviewVerifyReads},
		{"claim and acknowledgement", overviewVerifyApplied},
		{"stale and superseded requests", overviewVerifyStale},
		{"cancel, disconnect and close", overviewVerifyRevocation},
		{"request expiry", overviewVerifyExpiry},
		{"retired context capacity", overviewVerifyRetirement},
	} {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := scenario.run(ctx); err != nil {
			return fmt.Errorf("overview %s: %w", scenario.name, err)
		}
	}
	return nil
}

type overviewOutcome struct {
	result      transport.OverviewResult
	err         error
	completedAt time.Time
	contextErr  error
}

type overviewReplay struct {
	ctx    context.Context
	cancel context.CancelFunc
	broker *transport.OverviewBroker
	wg     sync.WaitGroup
}

func overviewNewReplay(parent context.Context, expiry time.Duration) *overviewReplay {
	ctx, cancel := context.WithTimeout(parent, 10*time.Second)
	return &overviewReplay{ctx: ctx, cancel: cancel, broker: transport.NewOverviewBroker(expiry)}
}

func (r *overviewReplay) close() {
	r.cancel()
	r.broker.Close()
	r.wg.Wait()
}

func (r *overviewReplay) connect() (string, <-chan transport.OverviewRequest, error) {
	delivered := make(chan transport.OverviewRequest, 8)
	id, err := r.broker.Connect(func(value any) error {
		request, ok := value.(transport.OverviewRequest)
		if !ok {
			return fmt.Errorf("unexpected delivery type %T", value)
		}
		select {
		case delivered <- request:
			return nil
		default:
			return fmt.Errorf("unexpected excess request deliveries")
		}
	})
	return id, delivered, err
}

func (r *overviewReplay) selectFilter(ctx context.Context, selection transport.OverviewSelection) <-chan overviewOutcome {
	result := make(chan overviewOutcome, 1)
	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		value, err := r.broker.SelectFilter(ctx, selection)
		result <- overviewOutcome{result: value, err: err, completedAt: time.Now(), contextErr: ctx.Err()}
	}()
	return result
}

func (r *overviewReplay) request(deliveries <-chan transport.OverviewRequest) (transport.OverviewRequest, error) {
	select {
	case request := <-deliveries:
		if request.RequestID == "" || request.ExpiresAt <= 0 {
			return request, fmt.Errorf("delivery lacks request identity or deadline")
		}
		return request, nil
	case <-r.ctx.Done():
		return transport.OverviewRequest{}, fmt.Errorf("waiting for delivery: %w", r.ctx.Err())
	}
}

func (r *overviewReplay) result(results <-chan overviewOutcome, status string) (transport.OverviewResult, error) {
	select {
	case outcome := <-results:
		if outcome.err != nil {
			return outcome.result, outcome.err
		}
		if outcome.result.Status != status {
			return outcome.result, fmt.Errorf("result status = %q, want %q", outcome.result.Status, status)
		}
		return outcome.result, nil
	case <-r.ctx.Done():
		return transport.OverviewResult{}, fmt.Errorf("waiting for %s result: %w", status, r.ctx.Err())
	}
}

func overviewString(value string) *string { return &value }

func overviewContext(id string, revision int64) transport.OverviewContext {
	return transport.OverviewContext{
		ContextID: id, Revision: revision, OverviewVisible: true, Focused: true, DocumentVisible: true,
		SelectedThread: &transport.OverviewThread{ThreadID: "thread-selected", TypeID: "report"},
		FollowUpThread: &transport.OverviewThread{ThreadID: "thread-follow-up", TypeID: "decision"},
		View:           "default", SelectedTag: overviewString("work"),
		Filters: []transport.OverviewFilter{
			{Tag: "work", Kind: "directory", Aliases: []string{"workspace"}, Count: 1,
				Threads: []transport.OverviewThread{{ThreadID: "thread-selected", TypeID: "report"}}},
			{Tag: "review", Kind: "semantic", Aliases: []string{}, Count: 0, Threads: []transport.OverviewThread{}},
		},
		RecentActions: []transport.OverviewAction{{Kind: "filter", At: 42, Tag: json.RawMessage(`"work"`),
			View: overviewString("default"), Thread: &transport.OverviewThread{ThreadID: "thread-selected", TypeID: "report"},
			Text: overviewString("fixed replay input")}},
	}
}

func overviewExecute(b *transport.OverviewBroker, path string, value any) (any, error) {
	raw, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	return b.Execute(path, raw)
}

func overviewPublish(b *transport.OverviewBroker, clientID string, value *transport.OverviewContext) error {
	_, err := overviewExecute(b, "/overview/context", map[string]any{"clientId": clientID, "context": value})
	return err
}

func overviewClaim(b *transport.OverviewBroker, clientID, requestID string, expected bool) error {
	value, err := overviewExecute(b, "/overview/claim", map[string]any{"clientId": clientID, "requestId": requestID})
	if err != nil {
		return err
	}
	if claimed, ok := value.(bool); !ok || claimed != expected {
		return fmt.Errorf("claim = %#v, want %t", value, expected)
	}
	return nil
}

func overviewAck(b *transport.OverviewBroker, clientID, requestID, status string, value transport.OverviewContext) error {
	_, err := overviewExecute(b, "/overview/ack", map[string]any{
		"clientId": clientID, "acknowledgement": map[string]any{"requestId": requestID, "status": status, "context": value},
	})
	return err
}

func overviewExpectCode(err error, code string) error {
	var typed *model.Error
	if !errors.As(err, &typed) || typed.Code != code {
		return fmt.Errorf("error = %v, want %s", err, code)
	}
	return nil
}

func overviewRead(ctx context.Context, b *transport.OverviewBroker) ([]transport.OverviewSnapshot, error) {
	value, err := b.ReadClients(ctx)
	if err != nil {
		return nil, err
	}
	snapshots, ok := value.([]transport.OverviewSnapshot)
	if !ok {
		return nil, fmt.Errorf("read returned %T", value)
	}
	return snapshots, nil
}

func overviewVerifyReads(ctx context.Context) error {
	r := overviewNewReplay(ctx, 5*time.Second)
	defer r.close()
	a, _, err := r.connect()
	if err != nil {
		return err
	}
	b, _, err := r.connect()
	if err != nil {
		return err
	}
	initial, err := overviewRead(r.ctx, r.broker)
	if err != nil || len(initial) != 0 || a == b || a == "" {
		return fmt.Errorf("new clients should be unique and invisible without contexts: %v, %v", initial, err)
	}
	first, second := overviewContext("context-first", 1), overviewContext("context-second", 1)
	if err := overviewPublish(r.broker, a, &first); err != nil {
		return err
	}
	if err := overviewPublish(r.broker, b, &second); err != nil {
		return err
	}
	snapshots, err := overviewRead(r.ctx, r.broker)
	if err != nil || len(snapshots) != 2 || snapshots[0].ClientID != a || snapshots[1].ClientID != b {
		return fmt.Errorf("client read order: %v, %v", snapshots, err)
	}
	changed := &snapshots[0]
	*changed.SelectedTag = "caller mutation"
	changed.SelectedThread.ThreadID = "caller mutation"
	changed.FollowUpThread.ThreadID = "caller mutation"
	changed.Filters[0].Aliases[0] = "caller mutation"
	changed.Filters[0].Threads[0].ThreadID = "caller mutation"
	changed.RecentActions[0].Tag[1] = 'X'
	*changed.RecentActions[0].Text = "caller mutation"
	*changed.RecentActions[0].View = "archived"
	changed.RecentActions[0].Thread.ThreadID = "caller mutation"
	again, err := overviewRead(r.ctx, r.broker)
	if err != nil || len(again) != 2 || !reflect.DeepEqual(again[0].OverviewContext, first) || !reflect.DeepEqual(again[1].OverviewContext, second) {
		return fmt.Errorf("read allowed caller mutation into broker state: %v", err)
	}
	if err := overviewVerifyRaw(r.broker, a, first); err != nil {
		return err
	}
	cancelled, cancel := context.WithCancel(r.ctx)
	cancel()
	if _, err := r.broker.ReadClients(cancelled); !errors.Is(err, context.Canceled) {
		return fmt.Errorf("cancelled read returned %v", err)
	}
	r.broker.Disconnect(a)
	remaining, err := overviewRead(r.ctx, r.broker)
	if err != nil || len(remaining) != 1 || !reflect.DeepEqual(remaining[0], again[1]) {
		return fmt.Errorf("disconnect damaged another client: %v", err)
	}
	return nil
}

func overviewVerifyRaw(b *transport.OverviewBroker, clientID string, fixture transport.OverviewContext) error {
	encoded, err := json.Marshal(fixture)
	if err != nil {
		return err
	}
	for _, invalid := range []struct{ name, old, replacement string }{
		{"missing field", `"focused":true,`, ""},
		{"unknown field", `"focused":true`, `"focused":true,"unknown":false`},
		{"null boolean", `"focused":true`, `"focused":null`},
		{"wrong boolean", `"focused":true`, `"focused":"true"`},
		{"fractional revision", `"revision":1`, `"revision":1.5`},
		{"unsafe revision", `"revision":1`, `"revision":9007199254740992`},
		{"negative revision", `"revision":1`, `"revision":-1`},
		{"UTF-16 context bound", `"contextId":"context-first"`, `"contextId":"` + strings.Repeat("😀", 129) + `"`},
		{"invalid view", `"view":"default"`, `"view":"hidden"`},
		{"unknown nested field", `"typeId":"report"`, `"typeId":"report","extra":1`},
		{"empty alias", `"aliases":["workspace"]`, `"aliases":[""]`},
		{"fractional count", `"count":1`, `"count":1.5`},
		{"duplicate filter", `"tag":"review"`, `"tag":"work"`},
		{"invalid action", `"kind":"filter"`, `"kind":"unknown"`},
		{"negative action time", `"at":42`, `"at":-1`},
		{"null action text", `"text":"fixed replay input"`, `"text":null`},
	} {
		mutated := strings.Replace(string(encoded), invalid.old, invalid.replacement, 1)
		if mutated == string(encoded) {
			return fmt.Errorf("validation fixture %s did not change", invalid.name)
		}
		_, err := overviewExecute(b, "/overview/context", map[string]any{"clientId": clientID, "context": json.RawMessage(mutated)})
		if err := overviewExpectCode(err, "INVALID_REQUEST"); err != nil {
			return fmt.Errorf("%s: %w", invalid.name, err)
		}
	}
	for _, invalid := range []struct {
		name string
		edit func(*transport.OverviewContext)
	}{
		{"null filters", func(c *transport.OverviewContext) { c.Filters = nil }},
		{"too many actions", func(c *transport.OverviewContext) {
			c.RecentActions = make([]transport.OverviewAction, 33)
			for i := range c.RecentActions {
				c.RecentActions[i] = transport.OverviewAction{Kind: "filter", At: 42}
			}
		}},
		{"too many aliases", func(c *transport.OverviewContext) {
			c.Filters[0].Aliases = make([]string, 2049)
			for i := range c.Filters[0].Aliases {
				c.Filters[0].Aliases[i] = "alias"
			}
		}},
	} {
		copy := overviewContext("context-first", 1)
		invalid.edit(&copy)
		if err := overviewExpectCode(overviewPublish(b, clientID, &copy), "INVALID_REQUEST"); err != nil {
			return fmt.Errorf("%s: %w", invalid.name, err)
		}
	}
	// JSON integer notation is intentionally compatible with the wire's number model.
	for _, revision := range []string{"1.0", "1e0"} {
		valid := strings.Replace(string(encoded), `"revision":1`, `"revision":`+revision, 1)
		if _, err := overviewExecute(b, "/overview/context", map[string]any{"clientId": clientID, "context": json.RawMessage(valid)}); err != nil {
			return fmt.Errorf("valid revision %s: %w", revision, err)
		}
	}
	selection := `{"clientId":"client-fixed","contextId":"context-fixed","revision":1,"tag":null}`
	for _, invalid := range []struct{ old, replacement string }{
		{`"tag":null`, `"tag":null,"extra":true`},
		{`,"tag":null`, ""},
		{`"clientId":"client-fixed"`, `"clientId":null`},
		{`"contextId":"context-fixed"`, `"contextId":""`},
		{`"revision":1`, `"revision":1.5`},
		{`"revision":1`, `"revision":9007199254740992`},
		{`"tag":null`, `"tag":""`},
		{`"tag":null`, `"tag":false`},
		{`"tag":null`, `"tag":"` + strings.Repeat("😀", 2049) + `"`},
	} {
		_, err := transport.ParseOverviewSelection(json.RawMessage(strings.Replace(selection, invalid.old, invalid.replacement, 1)))
		if err := overviewExpectCode(err, "INVALID_REQUEST"); err != nil {
			return fmt.Errorf("selection validation (%s): %w", invalid.old, err)
		}
	}
	validSelection := fmt.Sprintf(`{"clientId":%q,"contextId":"context-fixed","revision":1e0,"tag":%q}`, strings.Repeat("😀", 128), strings.Repeat("😀", 2048))
	parsed, err := transport.ParseOverviewSelection(json.RawMessage(validSelection))
	if err != nil || parsed.Revision != 1 || parsed.Tag == nil || *parsed.Tag != strings.Repeat("😀", 2048) {
		return fmt.Errorf("valid UTF-16 limits and exponent revision: %v", err)
	}
	for _, raw := range []json.RawMessage{json.RawMessage(`null`), json.RawMessage(`[]`), json.RawMessage(`{"clientId":`)} {
		if _, err := b.Execute("/overview/context", raw); overviewExpectCode(err, "INVALID_REQUEST") != nil {
			return fmt.Errorf("invalid context envelope accepted: %s", raw)
		}
	}
	return nil
}

func overviewVerifyApplied(ctx context.Context) error {
	r := overviewNewReplay(ctx, 5*time.Second)
	defer r.close()
	clientID, deliveries, err := r.connect()
	if err != nil {
		return err
	}
	initial := overviewContext("context-applied", 1)
	if err := overviewPublish(r.broker, clientID, &initial); err != nil {
		return err
	}
	selection := transport.OverviewSelection{ClientID: clientID, ContextID: initial.ContextID, Revision: 1, Tag: overviewString("review")}
	results := r.selectFilter(r.ctx, selection)
	request, err := r.request(deliveries)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(request.OverviewSelection, selection) {
		return fmt.Errorf("delivered selection changed")
	}
	updated := overviewContext(initial.ContextID, 2)
	updated.SelectedTag = overviewString("review")
	if err := overviewExpectCode(overviewAck(r.broker, clientID, request.RequestID, "applied", updated), "INVALID_REQUEST"); err != nil {
		return err
	}
	// The callback owns its delivered pointer, not the broker's pending tag.
	*request.Tag = "callback mutation"
	if err := overviewClaim(r.broker, clientID, request.RequestID, true); err != nil {
		return err
	}
	if err := overviewClaim(r.broker, clientID, request.RequestID, false); err != nil {
		return err
	}
	if err := overviewAck(r.broker, clientID, request.RequestID, "applied", updated); err != nil {
		return err
	}
	result, err := r.result(results, "applied")
	if err != nil {
		return err
	}
	if result.Context == nil || result.Context.ClientID != clientID || !reflect.DeepEqual(result.Context.OverviewContext, updated) {
		return fmt.Errorf("applied result did not contain acknowledged context")
	}
	*result.Context.SelectedTag = "caller mutation"
	current, err := overviewRead(r.ctx, r.broker)
	if err != nil || len(current) != 1 || !reflect.DeepEqual(current[0].OverviewContext, updated) {
		return fmt.Errorf("result snapshot did not isolate caller writes: %v", err)
	}
	return nil
}

func overviewVerifyStale(ctx context.Context) error {
	r := overviewNewReplay(ctx, 5*time.Second)
	defer r.close()
	clientID, deliveries, err := r.connect()
	if err != nil {
		return err
	}
	initial := overviewContext("context-stale", 3)
	if err := overviewPublish(r.broker, clientID, &initial); err != nil {
		return err
	}
	base := transport.OverviewSelection{ClientID: clientID, ContextID: initial.ContextID, Revision: 3, Tag: overviewString("review")}
	for _, stale := range []transport.OverviewSelection{
		{ClientID: clientID, ContextID: initial.ContextID, Revision: 2, Tag: base.Tag},
		{ClientID: clientID, ContextID: "retired-context", Revision: 3, Tag: base.Tag},
		{ClientID: clientID, ContextID: initial.ContextID, Revision: 3, Tag: overviewString("absent")},
	} {
		result, err := r.broker.SelectFilter(r.ctx, stale)
		if err != nil || result.Status != "stale" || result.Context == nil || result.Context.Revision != 3 {
			return fmt.Errorf("stale selection response: %+v, %v", result, err)
		}
	}
	select {
	case <-deliveries:
		return fmt.Errorf("stale selection was delivered")
	default:
	}
	firstResults := r.selectFilter(r.ctx, base)
	first, err := r.request(deliveries)
	if err != nil {
		return err
	}
	secondResults := r.selectFilter(r.ctx, base)
	second, err := r.request(deliveries)
	if err != nil {
		return err
	}
	if first.RequestID == second.RequestID {
		return fmt.Errorf("superseding requests reused identity")
	}
	if _, err := r.result(firstResults, "stale"); err != nil {
		return err
	}
	if err := overviewClaim(r.broker, clientID, first.RequestID, false); err != nil {
		return err
	}
	if err := overviewClaim(r.broker, clientID, second.RequestID, true); err != nil {
		return err
	}
	updated := overviewContext(initial.ContextID, 4)
	updated.SelectedTag = overviewString("review")
	if err := overviewAck(r.broker, clientID, second.RequestID, "applied", updated); err != nil {
		return err
	}
	if _, err := r.result(secondResults, "applied"); err != nil {
		return err
	}
	base.Revision = 4
	thirdResults := r.selectFilter(r.ctx, base)
	third, err := r.request(deliveries)
	if err != nil {
		return err
	}
	updated.Revision = 5
	if err := overviewPublish(r.broker, clientID, &updated); err != nil {
		return err
	}
	if err := overviewClaim(r.broker, clientID, third.RequestID, false); err != nil {
		return err
	}
	if _, err := r.result(thirdResults, "stale"); err != nil {
		return err
	}
	return nil
}

func overviewVerifyRevocation(ctx context.Context) error {
	r := overviewNewReplay(ctx, 5*time.Second)
	defer r.close()
	clientID, deliveries, err := r.connect()
	if err != nil {
		return err
	}
	initial := overviewContext("context-cancel", 1)
	if err := overviewPublish(r.broker, clientID, &initial); err != nil {
		return err
	}
	selection := transport.OverviewSelection{ClientID: clientID, ContextID: initial.ContextID, Revision: 1, Tag: overviewString("review")}
	cancelled, cancel := context.WithCancel(r.ctx)
	defer cancel()
	results := r.selectFilter(cancelled, selection)
	request, err := r.request(deliveries)
	if err != nil {
		return err
	}
	cancel()
	if err := overviewClaim(r.broker, clientID, request.RequestID, false); err != nil {
		return err
	}
	if _, err := r.result(results, "unavailable"); err != nil {
		return err
	}
	if _, err := r.broker.SelectFilter(cancelled, selection); !errors.Is(err, context.Canceled) {
		return fmt.Errorf("already cancelled selection returned %v", err)
	}
	results = r.selectFilter(r.ctx, selection)
	if _, err := r.request(deliveries); err != nil {
		return err
	}
	if err := overviewPublish(r.broker, clientID, nil); err != nil {
		return err
	}
	result, err := r.result(results, "unavailable")
	if err != nil || result.Context != nil {
		return fmt.Errorf("revoked context retained in result: %+v, %v", result, err)
	}
	if err := overviewExpectCode(overviewPublish(r.broker, clientID, &initial), "STALE_CONTEXT"); err != nil {
		return err
	}
	initial.ContextID = "context-disconnect"
	selection.ContextID = initial.ContextID
	if err := overviewPublish(r.broker, clientID, &initial); err != nil {
		return err
	}
	results = r.selectFilter(r.ctx, selection)
	request, err = r.request(deliveries)
	if err != nil {
		return err
	}
	r.broker.Disconnect(clientID)
	result, err = r.result(results, "unavailable")
	if err != nil || result.Context != nil {
		return fmt.Errorf("disconnect result: %+v, %v", result, err)
	}
	if err := overviewClaim(r.broker, clientID, request.RequestID, false); err != nil {
		return err
	}
	if err := overviewExpectCode(overviewPublish(r.broker, clientID, &initial), "OVERVIEW_UNAVAILABLE"); err != nil {
		return err
	}
	if result, err := r.broker.SelectFilter(r.ctx, selection); err != nil || result.Status != "unavailable" || result.Context != nil {
		return fmt.Errorf("disconnected selection: %+v, %v", result, err)
	}
	clientID, deliveries, err = r.connect()
	if err != nil {
		return err
	}
	if err := overviewPublish(r.broker, clientID, &initial); err != nil {
		return err
	}
	selection.ClientID = clientID
	results = r.selectFilter(r.ctx, selection)
	request, err = r.request(deliveries)
	if err != nil {
		return err
	}
	r.broker.Close()
	r.broker.Close()
	result, err = r.result(results, "unavailable")
	if err != nil || result.Context != nil {
		return fmt.Errorf("closed result: %+v, %v", result, err)
	}
	if _, _, err := r.connect(); overviewExpectCode(err, "SERVICE_STOPPING") != nil {
		return fmt.Errorf("closed broker accepted connect: %v", err)
	}
	if err := overviewClaim(r.broker, clientID, request.RequestID, false); err != nil {
		return err
	}
	clients, err := overviewRead(r.ctx, r.broker)
	if err != nil || len(clients) != 0 {
		return fmt.Errorf("closed broker retained clients: %v", err)
	}
	return nil
}

func overviewVerifyExpiry(ctx context.Context) error {
	r := overviewNewReplay(ctx, 100*time.Millisecond)
	defer r.close()
	clientID, deliveries, err := r.connect()
	if err != nil {
		return err
	}
	initial := overviewContext("context-expiry", 1)
	if err := overviewPublish(r.broker, clientID, &initial); err != nil {
		return err
	}
	started := time.Now()
	results := r.selectFilter(r.ctx, transport.OverviewSelection{ClientID: clientID, ContextID: initial.ContextID, Revision: 1})
	request, err := r.request(deliveries)
	if err != nil {
		return err
	}
	if request.ExpiresAt < started.Add(100*time.Millisecond).UnixMilli() {
		return fmt.Errorf("request deadline did not include configured expiry")
	}
	var outcome overviewOutcome
	select {
	case outcome = <-results:
	case <-r.ctx.Done():
		return fmt.Errorf("request did not expire: %w", r.ctx.Err())
	}
	if outcome.err != nil || outcome.result.Status != "unavailable" || outcome.contextErr != nil {
		return fmt.Errorf("expiry result: status=%q, error=%v, context=%v", outcome.result.Status, outcome.err, outcome.contextErr)
	}
	if outcome.completedAt.UnixMilli() < request.ExpiresAt {
		return fmt.Errorf("request became unavailable before its expiry")
	}
	result := outcome.result
	if result.Context == nil || !reflect.DeepEqual(result.Context.OverviewContext, initial) {
		return fmt.Errorf("expiry discarded live client context")
	}
	if err := overviewClaim(r.broker, clientID, request.RequestID, false); err != nil {
		return err
	}
	return nil
}

func overviewVerifyRetirement(ctx context.Context) error {
	r := overviewNewReplay(ctx, 5*time.Second)
	defer r.close()
	clientID, _, err := r.connect()
	if err != nil {
		return err
	}
	for i := 0; i <= 128; i++ {
		if err := r.ctx.Err(); err != nil {
			return err
		}
		current := overviewContext(fmt.Sprintf("retirement-%03d", i), 1)
		if err := overviewPublish(r.broker, clientID, &current); err != nil {
			return fmt.Errorf("retirement %d: %w", i, err)
		}
	}
	retired := overviewContext("retirement-000", 2)
	if err := overviewExpectCode(overviewPublish(r.broker, clientID, &retired), "STALE_CONTEXT"); err != nil {
		return err
	}
	excess := overviewContext("retirement-129", 1)
	if err := overviewExpectCode(overviewPublish(r.broker, clientID, &excess), "CAPACITY_EXHAUSTED"); err != nil {
		return err
	}
	if err := overviewExpectCode(overviewPublish(r.broker, clientID, nil), "CAPACITY_EXHAUSTED"); err != nil {
		return err
	}
	current := overviewContext("retirement-128", 2)
	if err := overviewPublish(r.broker, clientID, &current); err != nil {
		return err
	}
	clients, err := overviewRead(r.ctx, r.broker)
	if err != nil || len(clients) != 1 || !reflect.DeepEqual(clients[0].OverviewContext, current) {
		return fmt.Errorf("capacity rejection damaged current context: %v", err)
	}
	r.broker.Disconnect(clientID)
	clientID, _, err = r.connect()
	if err != nil {
		return err
	}
	if err := overviewPublish(r.broker, clientID, &retired); err != nil {
		return fmt.Errorf("new connection inherited retirements: %w", err)
	}
	return nil
}

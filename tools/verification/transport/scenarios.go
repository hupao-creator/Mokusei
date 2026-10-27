package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptrace"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

func verifyProfile(p profile.Profile, owner *profile.Ownership, directory string) {
	duplicate, err := profile.Acquire(p)
	if err == nil {
		_ = duplicate.Release()
		panic("two writers acquired one profile")
	}
	var failure *model.Error
	check(errors.As(err, &failure) && failure.Code == "PROFILE_IN_USE", "duplicate ownership did not fail closed")
	live, err := profile.HasLiveOwner(p)
	must(err)
	check(live, "owned profile has no live owner")
	info, err := os.Stat(filepath.Dir(p.LockPath))
	must(err)
	check(info.Mode().Perm() == 0700, "runtime metadata directory is not private")
	info, err = os.Stat(p.LockPath)
	must(err)
	check(info.Mode().Perm() == 0600, "ownership metadata is not private")
	alias := filepath.Join(directory, "profile-alias")
	must(os.Symlink(p.DataDir, alias))
	resolved, err := profile.Resolve(profile.Options{DataDir: alias, HomeDir: directory})
	must(err)
	check(resolved.DataDir == p.DataDir && profile.GuardPort(resolved) == profile.GuardPort(p), "profile alias changed single-writer identity")
	check(owner.Epoch != "", "ownership epoch missing")
}

func verifyDiscovery(p profile.Profile, expected profile.Connection) {
	actual, err := profile.ReadConnection(p)
	must(err)
	check(actual != nil && *actual == expected, "discovery did not round-trip")
	info, err := os.Stat(p.DiscoveryPath)
	must(err)
	check(info.Mode().Perm() == 0600, "discovery permissions are not private")
	must(os.Chmod(p.DiscoveryPath, 0644))
	_, err = profile.ReadConnection(p)
	check(err != nil, "public discovery permissions were accepted")
	must(os.Chmod(p.DiscoveryPath, 0600))
	alias := p
	alias.DiscoveryPath += ".symlink"
	must(os.Symlink(p.DiscoveryPath, alias.DiscoveryPath))
	_, err = profile.ReadConnection(alias)
	check(err != nil, "symlinked private metadata was accepted")
}

func verifyAuthentication(ctx context.Context, api *apiClient) {
	for _, scenario := range []struct {
		status int
		code   string
		adjust func(*http.Request)
	}{
		{401, "UNAUTHORIZED", func(r *http.Request) { r.Header.Del("Authorization") }},
		{401, "UNAUTHORIZED", func(r *http.Request) { r.Header.Set("Authorization", "Bearer wrong-token") }},
		{401, "UNAUTHORIZED", func(r *http.Request) { r.Header.Set("Origin", "https://untrusted.invalid") }},
		{401, "UNAUTHORIZED", func(r *http.Request) { r.Header.Set("Origin", "") }},
		{409, "PROTOCOL_MISMATCH", func(r *http.Request) { r.Header.Set("X-Mokusei-Protocol", "7") }},
		{409, "STALE_EPOCH", func(r *http.Request) { r.Header.Set("X-Mokusei-Epoch", "old-instance") }},
	} {
		api.request(ctx, "GET", "/health", nil, scenario.adjust).requireFailure(scenario.status, scenario.code)
	}
	health := api.request(ctx, "GET", "/health", nil, nil)
	health.requireStatus(200)
	check(health.object["status"] == "running", "health is not running")
	_, leaked := health.object["token"]
	check(!leaked, "health exposed the bearer credential")
	api.request(ctx, "GET", "/health?unexpected=1", nil, nil).requireFailure(404, "UNKNOWN_COMMAND")
	api.request(ctx, "POST", "/invoke/not-installed", map[string]any{}, nil).requireFailure(404, "UNKNOWN_COMMAND")
	api.request(ctx, "POST", "/invoke/application:command", map[string]any{"commandId": "too-short", "args": []any{}}, nil).requireFailure(400, "INVALID_REQUEST")
}

func verifyBodyLimits(ctx context.Context, api *apiClient) {
	api.request(ctx, "POST", "/overview/context", strings.Repeat("x", transport.MaxOverviewBytes), nil).requireFailure(400, "REQUEST_TOO_LARGE")
	connection, _, response := api.headerRequest(ctx, "/invoke/application:command", transport.MaxRequestBytes+1, true)
	rawReply(response).requireFailure(400, "REQUEST_TOO_LARGE")
	must(connection.Close())
	// Two declared 100 MiB bodies exceed the 192 MiB aggregate reservation.
	// Neither body is sent or allocated; 100 Continue proves the first reserved.
	first, reader, response := api.headerRequest(ctx, "/invoke/application:command", 100*1024*1024, true)
	defer first.Close()
	check(response.StatusCode == 100, "first bounded body reservation was not admitted")
	second, _, response := api.headerRequest(ctx, "/invoke/application:command", 100*1024*1024, true)
	rawReply(response).requireFailure(400, "CAPACITY_EXHAUSTED")
	must(second.Close())
	tcp, ok := first.(*net.TCPConn)
	check(ok, "fixture body reservation did not use TCP")
	must(tcp.CloseWrite())
	response, err := http.ReadResponse(reader, &http.Request{Method: "POST"})
	must(err)
	rawReply(response).requireFailure(400, "INVALID_REQUEST")
	must(first.Close())
}

func commandBody(id, mode string) map[string]any {
	return map[string]any{"commandId": id, "args": []any{mode}}
}

func fixedCommandID(label string) string {
	// Only the admission freshness prefix is dynamic. Labels and arguments are
	// fixed replay fixtures; no randomness or model/network result drives them.
	return fmt.Sprintf("%d_fixture_%s_00000000", time.Now().UnixMilli(), label)
}

func verifyAdmissionLimit(ctx context.Context, api *apiClient, host *mockHost) {
	const admitted = 16
	stream := api.events(ctx)
	defer stream.close()
	subscribe(ctx, api, stream, contentTarget("blocked-old-scope", "thread", ""))
	await(ctx, host.staleStarted, "content read did not start before command saturation")
	type correlatedReply struct {
		id string
		reply
	}
	responses := make(chan correlatedReply, admitted)
	for index := 0; index < admitted; index++ {
		id := fixedCommandID(fmt.Sprintf("capacity_%02d", index))
		go func() {
			responses <- correlatedReply{id: id, reply: api.request(ctx, "POST", "/invoke/state:load", commandBody(id, "capacity"), nil)}
		}()
	}
	for index := 0; index < admitted; index++ {
		await(ctx, host.gates["capacity"].started, "waiting for 16 admitted reads")
	}
	api.request(ctx, "POST", "/invoke/state:load", commandBody(fixedCommandID("overflow"), "capacity"), nil).requireFailure(503, "CAPACITY_EXHAUSTED")
	// Leaving a reading view must release its worker even while all command
	// slots are occupied by slow native discovery. Reopening must still work.
	subscribe(ctx, api, stream, nil)
	await(ctx, host.staleCanceled, "command saturation prevented content cleanup")
	subscribe(ctx, api, stream, contentTarget("during-command-saturation", "thread", ""))
	contentEvent(ctx, stream, "snapshot")
	subscribe(ctx, api, stream, nil)
	host.gates["capacity"].open()
	for index := 0; index < admitted; index++ {
		select {
		case response := <-responses:
			response.requireStatus(200)
			value, ok := response.object["value"].(map[string]any)
			check(ok && value["commandId"] == response.id, "read Host context lost its exact command ID")
		case <-ctx.Done():
			panic(ctx.Err())
		}
	}
}

func contentTarget(thread, kind, key string) any {
	scope := map[string]any{"kind": kind}
	if key != "" {
		scope["key"] = key
	}
	return map[string]any{"threadId": thread, "scope": scope}
}

func verifySessionAdmissionLimit(ctx context.Context, api *apiClient) {
	const admitted = 16
	for index := 0; index < admitted; index++ {
		connection, reader, response := api.headerRequest(ctx, "/thread-content/subscription", 2, true)
		defer func() {
			tcp, ok := connection.(*net.TCPConn)
			check(ok, "session reservation did not use TCP")
			must(tcp.CloseWrite())
			response, err := http.ReadResponse(reader, &http.Request{Method: "POST"})
			must(err)
			rawReply(response).requireFailure(400, "INVALID_REQUEST")
			must(connection.Close())
		}()
		check(response.StatusCode == 100, "bounded session request was not admitted")
	}
	api.request(ctx, "POST", "/thread-content/subscription", map[string]any{}, nil).requireFailure(503, "CAPACITY_EXHAUSTED")
	// The pools are separate in both directions. Partial session bodies still
	// have their normal body/socket bounds and must not consume command slots.
	api.request(ctx, "POST", "/invoke/state:load", commandBody(fixedCommandID("session-saturation"), ""), nil).requireStatus(200)
}

func subscribe(ctx context.Context, api *apiClient, stream *eventConnection, target any) {
	api.request(ctx, "POST", "/thread-content/subscription", map[string]any{"clientId": stream.id, "subscriptionId": "resource", "target": target}, nil).requireStatus(200)
}

func contentEvent(ctx context.Context, stream *eventConnection, kind string) map[string]any {
	outer := stream.next(ctx)
	check(outer["type"] == "thread-content", fmt.Sprintf("expected content event, got %v", outer["type"]))
	event, ok := outer["event"].(map[string]any)
	check(ok && event["type"] == kind && event["subscriptionId"] == "resource", fmt.Sprintf("expected %s content, got %v", kind, event))
	return event
}

func verifyContent(ctx context.Context, api *apiClient, host *mockHost, first, second *eventConnection) {
	subscribe(ctx, api, first, contentTarget("thread-one", "thread", ""))
	firstSnapshot := contentEvent(ctx, first, "snapshot")
	subscribe(ctx, api, second, contentTarget("thread-two", "turn", "turn-A"))
	secondSnapshot := contentEvent(ctx, second, "snapshot")
	check(firstSnapshot["revision"] == float64(1) && secondSnapshot["revision"] == float64(1), "initial content revisions are not local to each resource")
	firstValue := firstSnapshot["value"].(map[string]any)
	secondValue := secondSnapshot["value"].(map[string]any)
	check(firstValue["thread"] == "thread-one" && secondValue["thread"] == "thread-two" && secondValue["key"] == "turn-A", "content scopes leaked across clients")
	host.mutate("hello 😃")
	for _, stream := range []*eventConnection{first, second} {
		check(stream.next(ctx)["type"] == "mutation", "mutation event missing before content update")
		patch := contentEvent(ctx, stream, "patch")
		check(patch["baseRevision"] == float64(1) && patch["revision"] == float64(2), "content patch revision chain broke")
		operations := patch["patch"].([]any)
		check(len(operations) == 1, "fixed text change produced unexpected delta count")
		operation := operations[0].(map[string]any)
		check(operation["op"] == "text" && operation["index"] == float64(6) && operation["deleteCount"] == float64(2) && operation["text"] == "😃", "text delta offsets do not count UTF-16 units")
	}
	subscribe(ctx, api, first, contentTarget("blocked-old-scope", "thread", ""))
	await(ctx, host.staleStarted, "old content read did not start")
	subscribe(ctx, api, first, contentTarget("replacement", "execution", "execution-A"))
	await(ctx, host.staleCanceled, "replacement did not cancel old content read")
	replacement := contentEvent(ctx, first, "snapshot")
	check(replacement["revision"] == float64(1) && replacement["value"].(map[string]any)["thread"] == "replacement", "old content escaped its replaced subscription")
	subscribe(ctx, api, first, contentTarget("projection-panic", "thread", ""))
	projectionError := contentEvent(ctx, first, "error")
	check(projectionError["message"] == "Thread content presentation failed", "projection panic was not isolated to its resource")
	subscribe(ctx, api, first, contentTarget("after-error", "thread", ""))
	contentEvent(ctx, first, "snapshot")
	host.mutate("hello 😃 again")
	for _, stream := range []*eventConnection{first, second} {
		check(stream.next(ctx)["type"] == "mutation", "projection failure interrupted another client")
		contentEvent(ctx, stream, "patch")
	}
	subscribe(ctx, api, first, nil)
	subscribe(ctx, api, second, nil)
}

type commandReplay struct {
	id   string
	mode string
}

func verifyCommandReceipts(ctx context.Context, api *apiClient, host *mockHost) []commandReplay {
	id := fixedCommandID("duplicate")
	results := make(chan reply, 2)
	go func() {
		results <- api.request(ctx, "POST", "/invoke/application:command", commandBody(id, "duplicate"), nil)
	}()
	await(ctx, host.gates["duplicate"].started, "first write was not admitted")
	written := make(chan struct{}, 1)
	traceCtx := httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{WroteRequest: func(httptrace.WroteRequestInfo) { written <- struct{}{} }})
	go func() {
		results <- api.request(traceCtx, "POST", "/invoke/application:command", commandBody(id, "duplicate"), nil)
	}()
	await(ctx, written, "duplicate request was not written")
	host.gates["duplicate"].open()
	for index := 0; index < 2; index++ {
		select {
		case result := <-results:
			result.requireStatus(200)
			value := result.object["value"].(map[string]any)
			check(value["count"] == float64(1) && value["commandId"] == id, "duplicate command executed twice or lost its trace identity")
		case <-ctx.Done():
			panic(ctx.Err())
		}
	}
	api.request(ctx, "POST", "/invoke/application:command", commandBody(id, "changed-arguments"), nil).requireFailure(400, "COMMAND_ID_REUSED")
	lostID := fixedCommandID("lost")
	lostCtx, cancel := context.WithCancel(ctx)
	lost := make(chan reply, 1)
	go func() {
		lost <- api.request(lostCtx, "POST", "/invoke/application:command", commandBody(lostID, "lost"), nil)
	}()
	await(ctx, host.gates["lost"].started, "disconnected write was not admitted")
	cancel()
	select {
	case response := <-lost:
		check(errors.Is(response.err, context.Canceled), "HTTP disconnect fixture did not cancel its request")
	case <-ctx.Done():
		panic(ctx.Err())
	}
	host.gates["lost"].open()
	retry := api.request(ctx, "POST", "/invoke/application:command", commandBody(lostID, "lost"), nil)
	retry.requireStatus(200)
	value := retry.object["value"].(map[string]any)
	check(value["count"] == float64(1) && value["commandId"] == lostID, "disconnected admitted work was canceled or replayed")
	return []commandReplay{{id: id, mode: "duplicate"}, {id: lostID, mode: "lost"}}
}

func fingerprint(mode string) string {
	args, err := json.Marshal([]any{mode})
	must(err)
	hash := sha256.New()
	_, _ = hash.Write([]byte("host\x00application:command\x00"))
	_, _ = hash.Write(args)
	return hex.EncodeToString(hash.Sum(nil))
}

func verifyReceiptRecovery(ctx context.Context, p profile.Profile, replays []commandReplay) {
	store, err := transport.OpenReceiptStore(p.ReceiptsPath)
	must(err)
	called := false
	for _, replay := range replays {
		result, err := store.Execute(ctx, replay.id, fingerprint(replay.mode), func() (any, error) { called = true; return nil, nil })
		must(err)
		check(result.OK && !called, "completed receipt replay ran its command after reopening")
		var value map[string]any
		must(json.Unmarshal(result.Value, &value))
		check(value["count"] == float64(1) && value["commandId"] == replay.id, "reopened receipt changed its result")
	}
	recoveryPath := filepath.Join(filepath.Dir(p.ReceiptsPath), "recovered-pending.json")
	pendingID := fixedCommandID("recovered")
	must(profile.WritePrivateJSON(recoveryPath, map[string]any{"version": 1, "receipts": []any{
		map[string]any{"commandId": pendingID, "fingerprint": fingerprint("recovered"), "admittedAt": time.Now().UnixMilli()},
	}}))
	recovered, err := transport.OpenReceiptStore(recoveryPath)
	must(err)
	result, err := recovered.Execute(ctx, pendingID, fingerprint("recovered"), func() (any, error) { called = true; return nil, nil })
	must(err)
	check(!called && result.Error != nil && result.Error.Code == "COMMAND_OUTCOME_INDETERMINATE", "crash-recovered pending command was rerun")
	expiredID := fmt.Sprintf("%d_fixture_expired_00000000", time.Now().Add(-6*time.Minute).UnixMilli())
	_, err = recovered.Execute(ctx, expiredID, fingerprint("expired"), func() (any, error) { called = true; return nil, nil })
	var failure *model.Error
	check(errors.As(err, &failure) && failure.Code == "COMMAND_ID_EXPIRED" && !called, "expired command received a new admission")
	invalidPath := filepath.Join(filepath.Dir(p.ReceiptsPath), "invalid-receipt.json")
	must(profile.WritePrivateJSON(invalidPath, map[string]any{"version": 1, "receipts": []any{
		map[string]any{"commandId": pendingID, "fingerprint": fingerprint("recovered"), "admittedAt": 1, "completedAt": 2, "result": map[string]any{"error": map[string]any{"code": "FAILED", "message": "missing explicit ok"}}},
	}}))
	_, err = transport.OpenReceiptStore(invalidPath)
	check(err != nil, "malformed receipt outcome did not fail closed")
}

func verifyOverviewHTTP(ctx context.Context, api *apiClient, broker *transport.OverviewBroker, stream *eventConnection) {
	contextValue := func(revision int, tag, scope any) map[string]any {
		return map[string]any{"contextId": "renderer-one", "revision": revision, "overviewVisible": true, "focused": true, "documentVisible": true, "mokuOpen": false, "settingsOpen": false, "selectedThread": nil, "followUpThread": nil, "view": "default", "selectedTag": tag, "selectedScope": scope, "filters": []any{map[string]any{"tag": "feature", "scope": "inbox", "kind": "semantic", "aliases": []string{}, "count": 1, "threads": []any{}}}, "recentActions": []any{}}
	}
	api.request(ctx, "POST", "/overview/context", map[string]any{"clientId": stream.id, "context": contextValue(1, nil, nil)}, nil).requireStatus(200)
	results := make(chan transport.OverviewResult, 1)
	errors := make(chan error, 1)
	tag, scope := "feature", "inbox"
	go func() {
		result, err := broker.SelectFilter(ctx, transport.OverviewSelection{ClientID: stream.id, ContextID: "renderer-one", Revision: 1, Scope: &scope, Tag: &tag})
		if err != nil {
			errors <- err
			return
		}
		results <- result
	}()
	event := stream.next(ctx)
	check(event["type"] == "overview-filter", "overview request did not enter the NDJSON stream")
	request := event["request"].(map[string]any)
	check(request["scope"] == "inbox", "overview request did not carry the selection scope")
	claim := api.request(ctx, "POST", "/overview/claim", map[string]any{"clientId": stream.id, "requestId": request["requestId"]}, nil)
	claim.requireStatus(200)
	check(claim.object["value"] == true, "renderer could not claim its current selection")
	api.request(ctx, "POST", "/overview/ack", map[string]any{"clientId": stream.id, "acknowledgement": map[string]any{"requestId": request["requestId"], "status": "applied", "context": contextValue(2, "feature", "inbox")}}, nil).requireStatus(200)
	select {
	case result := <-results:
		check(result.Status == "applied" && result.Context != nil && result.Context.Revision == 2, "overview HTTP acknowledgement did not settle selection")
	case err := <-errors:
		panic(err)
	case <-ctx.Done():
		panic(ctx.Err())
	}
}

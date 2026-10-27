package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/daemon"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type shutdownHost struct {
	*mockHost
	entered   chan string
	canceled  chan string
	release   chan struct{}
	once      sync.Once
	committed bool
}

func (h *shutdownHost) Initialize(context.Context) (transport.Host, error) { return h, nil }
func (*shutdownHost) Close(context.Context) error                          { return nil }
func (h *shutdownHost) finish()                                            { h.once.Do(func() { close(h.release) }) }

func (h *shutdownHost) Invoke(ctx context.Context, channel string, _ []json.RawMessage) (any, error) {
	h.entered <- channel
	select {
	case <-ctx.Done():
		h.canceled <- channel
		// Cancellation must precede joining. Keep the call alive until the replay
		// has checked that shutdown still retains discovery and the profile lease.
		<-h.release
		if h.committed && channel == "application:command" {
			// Cancellation can arrive after commit but before its result returns.
			return map[string]any{"committed": true, "commandId": transport.CommandID(ctx)}, nil
		}
		return nil, ctx.Err()
	case <-h.release:
		return nil, errors.New("fixture released before service cancellation")
	}
}

func verifyCommandShutdown(ctx context.Context, directory string) {
	for _, committed := range []bool{false, true} {
		verifyCommandShutdownOutcome(ctx, directory, committed)
	}
	fmt.Println("PASS command shutdown: admitted reads/writes canceled before drain; management response and profile lease retained until join; canceled and committed write receipts survive reopen without re-execution")
}

func verifyCommandShutdownOutcome(ctx context.Context, directory string, committed bool) {
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(directory, fmt.Sprintf("command-shutdown-%t", committed)), HomeDir: directory})
	must(err)
	host := &shutdownHost{mockHost: newMockHost(), entered: make(chan string, 2), canceled: make(chan string, 2), release: make(chan struct{}), committed: committed}
	serviceCtx, cancelService := context.WithCancel(ctx)
	serviceDone := make(chan error, 1)
	go func() { serviceDone <- daemon.Serve(serviceCtx, daemon.ServeOptions{Profile: p, Bootstrap: host}) }()
	defer func() {
		host.finish()
		cancelService()
		select {
		case err := <-serviceDone:
			must(err)
		case <-time.After(5 * time.Second):
			panic("command-shutdown fixture did not release its service")
		}
	}()
	ready, cancelReady := context.WithTimeout(ctx, 3*time.Second)
	defer cancelReady()
	var connection *profile.Connection
	for connection == nil {
		connection, err = daemon.Status(ready, p)
		must(err)
		if connection == nil {
			select {
			case err := <-serviceDone:
				serviceDone <- err
				panic(fmt.Errorf("command-shutdown service exited before publishing discovery: %w", err))
			case <-ready.Done():
				panic("command-shutdown service did not publish discovery")
			case <-time.After(5 * time.Millisecond):
			}
		}
	}
	api := newAPI(*connection)
	defer api.close()
	requests, cancelRequests := context.WithCancel(ctx)
	defer cancelRequests()
	replies := make(chan reply, 2)
	writeID := fixedCommandID("shutdown")
	go func() {
		replies <- api.request(requests, "POST", "/invoke/application:command", commandBody(writeID, "shutdown"), nil)
	}()
	go func() {
		replies <- api.request(requests, "POST", "/invoke/state:load", commandBody(fixedCommandID("shutdown_read"), "shutdown"), nil)
	}()
	for range 2 {
		select {
		case <-host.entered:
		case <-ready.Done():
			panic("shutdown fixture command was not admitted")
		}
	}
	stopping, cancelStop := context.WithTimeout(ctx, 3*time.Second)
	defer cancelStop()
	stopDone := make(chan error, 1)
	go func() { stopDone <- daemon.Stop(stopping, p) }()
	canceled := map[string]bool{}
	for range 2 {
		select {
		case channel := <-host.canceled:
			canceled[channel] = true
		case <-stopping.Done():
			panic("service shutdown did not cancel both admitted read and write calls before Drain")
		}
	}
	check(canceled["state:load"] && canceled["application:command"], "shutdown cancellation did not reach both command kinds")
	health := api.request(ctx, "GET", "/health", nil, nil)
	health.requireStatus(200)
	check(health.object["status"] == "stopping", "management endpoint did not remain available during command drain")
	live, err := profile.HasLiveOwner(p)
	must(err)
	check(live, "profile lease was released before admitted commands returned")
	select {
	case <-stopDone:
		panic("stop completed before admitted commands returned")
	default:
	}
	host.finish()
	select {
	case err := <-stopDone:
		must(err)
	case <-stopping.Done():
		panic("stop did not finish after admitted commands returned")
	}
	for range 2 {
		select {
		case <-replies:
		case <-stopping.Done():
			panic("shutdown left an HTTP command waiter alive")
		}
	}
	connection, err = profile.ReadConnection(p)
	must(err)
	check(connection == nil, "successful command drain retained discovery")
	owner, err := profile.Acquire(p)
	must(err)
	defer func() { must(owner.Release()) }()
	receipts, err := transport.OpenReceiptStore(p.ReceiptsPath)
	must(err)
	replayed := false
	result, err := receipts.Execute(ctx, writeID, fingerprint("shutdown"), func() (any, error) { replayed = true; return nil, nil })
	must(err)
	check(!replayed, "reopened shutdown receipt re-executed its command")
	if committed {
		check(result.OK && result.Error == nil, "shutdown replaced a committed command's success with cancellation")
		var value struct {
			Committed bool   `json:"committed"`
			CommandID string `json:"commandId"`
		}
		must(json.Unmarshal(result.Value, &value))
		check(value.Committed && value.CommandID == writeID, "reopened receipt lost the committed command result")
	} else {
		check(!result.OK && result.Error != nil && result.Error.Message == context.Canceled.Error(), "shutdown did not persist the canceled command outcome before releasing ownership")
	}
}

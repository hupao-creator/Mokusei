// Command transport replays fixed local protocol scenarios without a Harness,
// a model provider, Node, or production profile data.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

func main() {
	swiftDeltas := flag.Bool("swift-deltas", false, "verify Go content deltas with the real Swift Core consumer")
	swiftFiles := flag.Bool("swift-files", false, "verify host-file transfers with the real Swift Core client")
	swiftSettings := flag.Bool("swift-settings-capacity", false, "verify cold settings admission and cancellation with the real Swift client")
	flag.Parse()
	if *swiftSettings {
		if err := verifySwiftSettingsCapacity(); err != nil {
			fmt.Fprintln(os.Stderr, "FAIL Go/Swift settings capacity replay:", err)
			os.Exit(1)
		}
		return
	}
	if *swiftDeltas {
		if err := verifySwiftDeltas(); err != nil {
			fmt.Fprintln(os.Stderr, "FAIL Go/Swift delta replay:", err)
			os.Exit(1)
		}
		return
	}
	if *swiftFiles {
		if err := verifySwiftFiles(); err != nil {
			fmt.Fprintln(os.Stderr, "FAIL Go/Swift file replay:", err)
			os.Exit(1)
		}
		return
	}
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "FAIL transport replay:", err)
		os.Exit(1)
	}
	fmt.Println("PASS transport replay: profile ownership/privacy; HTTP authorization and bounded admission; multi-client content/UTF-16 deltas; overview lifecycle; durable command recovery; protected shutdown")
}

func run() (failure error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			failure = fmt.Errorf("%v", recovered)
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	directory, err := os.MkdirTemp("", "mokusei-transport-replay-")
	must(err)
	defer func() { failure = errors.Join(failure, os.RemoveAll(directory)) }()
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(directory, "data"), HomeDir: directory})
	must(err)
	owner, err := profile.Acquire(p)
	must(err)
	defer func() { failure = errors.Join(failure, owner.Release()) }()
	verifyProfile(p, owner, directory)
	verifyContentWorkers(ctx, directory)
	verifyFileWorkerShutdown(ctx, directory)
	verifyCommandShutdown(ctx, directory)
	host := newMockHost()
	defer host.releaseAll()
	var server *transport.Server
	server, err = transport.Start(transport.Options{
		Profile: p, Epoch: owner.Epoch, Host: host,
		RequestStop: func(stopCtx context.Context) error {
			server.Revoke()
			if err := server.Drain(stopCtx); err != nil {
				return err
			}
			return server.Close(stopCtx)
		},
	})
	must(err)
	defer func() {
		host.releaseAll()
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		failure = errors.Join(failure, server.Close(cleanup), server.Finish(cleanup))
	}()
	api := newAPI(server.Connection)
	defer api.close()
	must(profile.PublishConnection(p, server.Connection))
	verifyDiscovery(p, server.Connection)
	verifyAuthentication(ctx, api)
	verifyBodyLimits(ctx, api)
	verifyAdmissionLimit(ctx, api, host)
	verifySessionAdmissionLimit(ctx, api)
	first := api.events(ctx)
	defer first.close()
	second := api.events(ctx)
	defer second.close()
	check(first.id != second.id, "separate event streams shared one client identity")
	verifyContent(ctx, api, host, first, second)
	verifyOverviewHTTP(ctx, api, server.Overview(), first)
	must(verifyOverview(ctx))
	replays := verifyCommandReceipts(ctx, api, host)
	stopped := api.request(ctx, "POST", "/stop", nil, nil)
	stopped.requireStatus(200)
	check(stopped.object["ok"] == true, "stop response was truncated while closing its server")
	// Finish must run after the /stop HTTP response, never inside its handler.
	must(server.Finish(ctx))
	verifyReceiptRecovery(ctx, p, replays)
	must(profile.RemoveConnection(p, "another-epoch"))
	connection, err := profile.ReadConnection(p)
	must(err)
	check(connection != nil, "a foreign epoch removed discovery metadata")
	must(profile.RemoveConnection(p, owner.Epoch))
	connection, err = profile.ReadConnection(p)
	must(err)
	check(connection == nil, "owned discovery metadata survived removal")
	must(owner.Release())
	replacement, err := profile.Acquire(p)
	must(err)
	must(replacement.Release())
	return nil
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func check(condition bool, message string) {
	if !condition {
		panic(message)
	}
}

func await(ctx context.Context, signal <-chan struct{}, message string) {
	select {
	case <-signal:
	case <-ctx.Done():
		panic(fmt.Errorf("%s: %w", message, ctx.Err()))
	}
}

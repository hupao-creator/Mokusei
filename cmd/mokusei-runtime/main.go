// mokusei-runtime manages the independently owned background service. The
// claude-mcp entry point shares this binary but never opens an application profile.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/composition"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/platform/daemon"
	"github.com/hupao-creator/Mokusei/internal/platform/diagnostics"
	"github.com/hupao-creator/Mokusei/internal/platform/environment"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
)

const usage = "Usage: mokusei-runtime <start|status|stop|serve> [--data-dir <directory>]"

func main() {
	if err := run(os.Args[1:], os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		if errors.Is(err, context.Canceled) {
			os.Exit(130)
		}
		os.Exit(1)
	}
}

func run(args []string, input io.Reader, output io.Writer) error {
	// Claude launches this subcommand as an MCP stdio peer. Profile discovery,
	// signal handlers, service startup and status logging must not precede it.
	if len(args) > 0 && args[0] == "claude-mcp" {
		if len(args) != 1 {
			return errors.New("claude-mcp does not accept command-line options")
		}
		return claude.ServeMCP(context.Background(), input, output, claude.MCPOptionsFromEnvironment())
	}
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" {
		_, err := fmt.Fprintln(output, usage)
		return err
	}
	command, dataDir, err := parseCommand(args)
	if err != nil {
		return err
	}
	if command == "serve" {
		if err := daemon.AwaitLaunch(); err != nil {
			return err
		}
	}
	p, err := profile.Resolve(profile.Options{DataDir: dataDir})
	if err != nil {
		return err
	}
	if command == "start" || command == "serve" {
		if err = profile.Prepare(p); err != nil {
			return err
		}
		// Creation fixes the filesystem spelling of previously missing paths.
		// Build the application and its workspace from that stable identity.
		p, err = profile.Refresh(p)
		if err != nil {
			return err
		}
	}
	ctx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()
	env := environment.Current()
	switch command {
	case "serve":
		bootstrap := &loggedBootstrap{directory: filepath.Join(p.DataDir, "runtime", "debug-logs")}
		overview := transport.NewOverviewBroker(10 * time.Second)
		defer overview.Close()
		bootstrap.inner = composition.New(composition.Options{
			Profile: p, Environment: env,
			Headless: env["MOKUSEI_HEADLESS"] == "1",
			Log:      bootstrap.event, Overview: overview,
			SettingsTrace: bootstrap.settingsEvent,
			SearchTrace:   bootstrap.searchEvent,
		})
		err = daemon.Serve(ctx, daemon.ServeOptions{
			Profile: p, Bootstrap: bootstrap, Output: output, Overview: overview,
			Log: func(err error) {
				bootstrap.event("runtime", err)
				// Bootstrap cleanup closes the private logger before the daemon's
				// final ownership decision. Keep that failure in process.log too.
				message := err.Error()
				if len(message) > 7*1024 {
					message = message[:7*1024]
				}
				fmt.Fprintln(os.Stderr, message)
			},
		})
		// A termination request during startup is an orderly shutdown, just as
		// it is after the service has published its discovery record.
		if ctx.Err() != nil && errors.Is(err, context.Canceled) {
			return nil
		}
		return err
	case "start":
		cwd, err := os.Getwd()
		if err != nil {
			return err
		}
		connection, err := daemon.Ensure(ctx, p, daemon.LaunchOptions{Directory: cwd, Environment: environment.Slice(env)})
		if err != nil {
			return err
		}
		if connection == nil {
			return errors.New("runtime did not publish a connection")
		}
		return writeStatus(output, p, connection)
	case "status":
		connection, err := daemon.Status(ctx, p)
		if err != nil {
			return err
		}
		return writeStatus(output, p, connection)
	case "stop":
		if err := daemon.Stop(ctx, p); err != nil {
			return err
		}
		return writeStatus(output, p, nil)
	}
	return errors.New("unknown runtime command")
}

// Logs share the service's profile lease. Opening the logger in Initialize
// prevents a competing serve process from rotating the active owner's files;
// closing it with the application flushes diagnostics before lease release.
type loggedBootstrap struct {
	inner       daemon.Bootstrap
	directory   string
	mu          sync.Mutex
	logger      *diagnostics.Logger
	initialized bool
}

func (b *loggedBootstrap) Initialize(ctx context.Context) (transport.Host, error) {
	logger, err := diagnostics.New(b.directory)
	if err != nil {
		return nil, err
	}
	b.mu.Lock()
	b.logger = logger
	b.initialized = true
	b.mu.Unlock()
	return b.inner.Initialize(ctx)
}

func (b *loggedBootstrap) event(kind string, err error) {
	b.mu.Lock()
	logger := b.logger
	b.mu.Unlock()
	if logger != nil {
		logger.Event(kind, err)
	}
}

func (b *loggedBootstrap) settingsEvent(event string, fields model.Object) {
	b.mu.Lock()
	logger := b.logger
	b.mu.Unlock()
	if logger != nil {
		logger.SettingsEvent(event, fields)
	}
}

func (b *loggedBootstrap) Close(ctx context.Context) error {
	b.mu.Lock()
	logger, initialized := b.logger, b.initialized
	b.mu.Unlock()
	var err error
	if initialized {
		err = b.inner.Close(ctx)
	}
	if err != nil {
		b.event("runtime.shutdown.failed", err)
	}
	return errors.Join(err, logger.Close())
}

func parseCommand(args []string) (command, dataDir string, err error) {
	command = args[0]
	switch command {
	case "start", "status", "stop", "serve":
	default:
		return "", "", errors.New("unknown runtime command")
	}
	// Keep the existing invocation contract: one optional --data-dir pair,
	// with duplicate options and trailing arguments rejected before any I/O.
	if len(args) == 1 {
		return command, "", nil
	}
	if len(args) != 3 || args[1] != "--data-dir" || args[2] == "" || strings.HasPrefix(args[2], "--") {
		return "", "", errors.New("expected --data-dir <directory>")
	}
	return command, args[2], nil
}

func writeStatus(output io.Writer, p profile.Profile, connection *profile.Connection) error {
	// Discovery credentials stay in the private connection file. Management
	// output is a stable, single-line JSON status for launchers and shell users.
	status := struct {
		Status  string `json:"status"`
		PID     int    `json:"pid,omitempty"`
		Epoch   string `json:"epoch,omitempty"`
		DataDir string `json:"dataDir"`
	}{Status: "stopped", DataDir: p.DataDir}
	if connection != nil {
		status.Status, status.PID, status.Epoch = "running", connection.PID, connection.Epoch
		status.DataDir = connection.DataDir
	}
	return json.NewEncoder(output).Encode(status)
}

func (b *loggedBootstrap) searchEvent(event plugin.SearchDiagnostic) {
	b.mu.Lock()
	logger := b.logger
	b.mu.Unlock()
	if logger != nil {
		logger.SearchEvent(event)
	}
}

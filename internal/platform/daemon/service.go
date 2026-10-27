package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

// Bootstrap must not open storage or native resources in its constructor.
// Initialize owns all acquisitions, and Close joins every acquired participant.
// A partial Initialize failure still requires Close, under the same profile.
type Bootstrap interface {
	Initialize(context.Context) (transport.Host, error)
	Close(context.Context) error
}

type ServeOptions struct {
	Profile   profile.Profile
	Bootstrap Bootstrap
	Output    io.Writer
	Log       func(error)
	Overview  *transport.OverviewBroker
}

func Serve(ctx context.Context, options ServeOptions) error {
	if options.Bootstrap == nil {
		return errors.New("runtime bootstrap is required")
	}
	owner, err := profile.Acquire(options.Profile)
	if err != nil {
		return err
	}
	lifetime, cancel := context.WithCancel(context.Background())
	defer cancel()
	var mu sync.Mutex
	var server *transport.Server
	var stopping bool
	var closeOnce sync.Once
	initialized := make(chan struct{})
	stopped := make(chan struct{})
	var stopErr error
	log := func(err error) {
		if err != nil && options.Log != nil {
			options.Log(err)
		}
	}
	stop := func(stopContext context.Context) error {
		closeOnce.Do(func() {
			mu.Lock()
			stopping = true
			current := server
			mu.Unlock()
			cancel() // Revoke acquisition and all producer contexts synchronously.
			if current != nil {
				current.Revoke()
			}
			go func() {
				<-initialized
				mu.Lock()
				current := server
				mu.Unlock()
				if current != nil {
					current.Revoke()
				}
				var wg sync.WaitGroup
				var appErr, drainErr error
				wg.Add(1)
				go func() { defer wg.Done(); appErr = options.Bootstrap.Close(context.Background()) }()
				if current != nil {
					wg.Add(1)
					go func() { defer wg.Done(); drainErr = current.Drain(context.Background()) }()
				}
				wg.Wait()
				stopErr = errors.Join(appErr, drainErr)
				// Every participant and admitted call has finished cleanup. An
				// error is diagnostic evidence, not permission to hold the profile
				// forever and prevent the user's next launch.
				stopErr = errors.Join(stopErr, profile.RemoveConnection(options.Profile, owner.Epoch), owner.Release())
				if current != nil {
					stopErr = errors.Join(stopErr, current.Close(context.Background()))
				}
				if stopErr != nil {
					log(errors.Join(errors.New("runtime shutdown completed with cleanup errors"), stopErr))
				}
				close(stopped)
			}()
		})
		select {
		case <-stopped:
			return stopErr
		case <-stopContext.Done():
			return stopContext.Err()
		}
	}
	watchDone := make(chan struct{})
	defer close(watchDone)
	go func() {
		select {
		case <-ctx.Done():
			_ = stop(context.Background())
		case <-watchDone:
		}
	}()
	host, openErr := options.Bootstrap.Initialize(lifetime)
	if openErr == nil {
		mu.Lock()
		if stopping {
			openErr = context.Canceled
		} else {
			server, openErr = transport.Start(transport.Options{Profile: options.Profile, Epoch: owner.Epoch, Host: host, Overview: options.Overview, RequestStop: stop})
			if openErr == nil {
				openErr = profile.PublishConnection(options.Profile, server.Connection)
			}
		}
		mu.Unlock()
	}
	close(initialized)
	if openErr != nil {
		if !errors.Is(openErr, context.Canceled) {
			_ = profile.RecordStartupFailure(options.Profile, openErr)
		}
		if cleanupErr := stop(context.Background()); cleanupErr == nil {
			return openErr
		}
	} else if options.Output != nil {
		if err = json.NewEncoder(options.Output).Encode(map[string]any{"status": "running", "pid": server.Connection.PID, "epoch": owner.Epoch, "dataDir": options.Profile.DataDir}); err != nil {
			log(err)
		}
	}
	<-stopped
	if server != nil {
		finish, cancelFinish := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancelFinish()
		// Go main must wait for the /stop handler to flush its response before
		// process exit. This runs outside the handler, avoiding a shutdown cycle.
		if err = server.Finish(finish); err != nil {
			return errors.Join(openErr, stopErr, err)
		}
	}
	return errors.Join(openErr, stopErr)
}

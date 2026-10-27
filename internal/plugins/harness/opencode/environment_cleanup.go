package opencode

import (
	"errors"
	"syscall"
	"time"
)

// Native cache flushes can race directory removal even after the owned server
// group has exited. Retry only ENOTEMPTY, and keep the final error if cleanup
// cannot settle. This does not replace process shutdown or prove that a worker
// has exited; callers must still perform their normal lifecycle cleanup first.
func cleanupTemporaryEnvironment(remove func() error) error {
	deadline := time.Now().Add(2 * time.Second)
	for {
		err := remove()
		if !errors.Is(err, syscall.ENOTEMPTY) || !time.Now().Before(deadline) {
			return err
		}
		time.Sleep(min(20*time.Millisecond, time.Until(deadline)))
	}
}

package processgroup

import (
	"errors"
	"fmt"
	"syscall"
	"time"
)

// DrainAfterExit joins descendants in an owned group after its leader was reaped.
// A successful leader exit alone is not proof that native plugin workers stopped.
// Callers must not remove execution directories until this returns nil.
func DrainAfterExit(pgid int) error {
	if pgid <= 1 {
		return errors.New("invalid owned process group")
	}
	retired := false
	stopped := func() (bool, error) {
		if retired {
			return true, nil
		}
		err := syscall.Kill(-pgid, 0)
		if errors.Is(err, syscall.ESRCH) {
			retired = true
			return true, nil
		}
		// Darwin returns EPERM for a group containing only zombies. A bounded
		// process-table scan must confirm there are no executing members before
		// treating that permission failure as cleanup (the zombies may be reaped
		// between the signal probe and this scan).
		if groupStopped(pgid) {
			retired = true
			return true, nil
		}
		if err != nil {
			return false, fmt.Errorf("inspect owned process group %d: %w", pgid, err)
		}
		return false, nil
	}
	for _, stage := range []struct {
		signal syscall.Signal
		wait   time.Duration
	}{{0, 200 * time.Millisecond}, {syscall.SIGTERM, time.Second}, {syscall.SIGKILL, 2 * time.Second}} {
		done, err := stopped()
		if err != nil {
			return err
		}
		if done {
			return nil
		}
		if stage.signal != 0 {
			if err = syscall.Kill(-pgid, stage.signal); err != nil && !errors.Is(err, syscall.ESRCH) {
				// The last live member can exit after the probe, making Darwin's
				// signal return EPERM too. Apply the same proof before failing.
				if done, inspectErr := stopped(); done {
					return nil
				} else {
					return errors.Join(fmt.Errorf("signal owned process group %d: %w", pgid, err), inspectErr)
				}
			}
		}
		deadline := time.Now().Add(stage.wait)
		for time.Now().Before(deadline) {
			time.Sleep(20 * time.Millisecond)
			done, err = stopped()
			if err != nil {
				return err
			}
			if done {
				return nil
			}
		}
	}
	return ErrCleanup
}

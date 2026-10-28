package moku

import "github.com/hupao-creator/Mokusei/internal/core/plugin"

// The caller retains the coordinator queue and settings admission gate. Core
// can reject an unconsumed follow-up when its old execution ended during
// preparation. Rebuild both configuration and context once before the successor;
// any other error, including a joined/uncertain failure, must not resend input.
func retryConfigurationAdmission(operation func() error) error {
	err := operation()
	if err == plugin.ErrMokuConfigurationPending {
		return operation()
	}
	return err
}

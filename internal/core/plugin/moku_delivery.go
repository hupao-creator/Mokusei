package plugin

import (
	"errors"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// ErrMokuConfigurationPending is returned by Core before starting a new Moku
// execution when saved settings still need applying. No input was consumed;
// the coordinator may prepare its configuration and context again before Send.
// Native Harness errors and uncertain acknowledgements must never use it.
var ErrMokuConfigurationPending = errors.New("Moku configuration must be applied before new execution admission")

// MokuDelivery is a committed terminal fact awaiting coordinator admission.
// Uncertain means native Send may have consumed it; automatic replay is unsafe.
type MokuDelivery struct {
	ID           string             `json:"id"`
	Thread       model.ThreadRecord `json:"thread"`
	AttemptEpoch string             `json:"attemptEpoch,omitempty"`
	Uncertain    bool               `json:"uncertain,omitempty"`
}

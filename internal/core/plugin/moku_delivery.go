package plugin

import "github.com/hupao-creator/Mokusei/internal/core/model"

// MokuDelivery is a committed terminal fact awaiting coordinator admission.
// Uncertain means native Send may have consumed it; automatic replay is unsafe.
type MokuDelivery struct {
	ID           string             `json:"id"`
	Thread       model.ThreadRecord `json:"thread"`
	AttemptEpoch string             `json:"attemptEpoch,omitempty"`
	Uncertain    bool               `json:"uncertain,omitempty"`
}

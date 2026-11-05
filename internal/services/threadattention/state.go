// Package threadattention owns reading evidence and reversible Overview visibility.
package threadattention

import "time"

const (
	FallbackInterval = 24 * time.Hour
	ReadDelay        = time.Hour
	VisibleThreshold = 20
)

// A visit spans one real reader entry. Returning from the background resumes
// the same visit, while entering the reader again creates a new identity.
type Visit struct {
	ID               string `json:"id"`
	OpenedAt         int64  `json:"openedAt"`
	ForegroundMillis int64  `json:"foregroundMillis"`
}

type Thread struct {
	Generation        uint64  `json:"generation"`
	Visits            []Visit `json:"visits"`
	Hidden            bool    `json:"hidden"`
	Revision          uint64  `json:"revision"`
	LatestExecution   string  `json:"latestExecution"`
	LatestCompleted   bool    `json:"latestCompleted"`
	LastCompletedAt   int64   `json:"lastCompletedAt"`
	FirstReadAt       int64   `json:"firstReadAt"`
	ReadWakeDelivered bool    `json:"readWakeDelivered"`
}

// Start invalidates both an outstanding hide decision and the previous read
// deadline. Replaying admission for the same execution has no effect.
func (t *Thread) Start(execution string) {
	if execution == t.LatestExecution {
		return
	}
	t.Generation++
	t.LatestExecution = execution
	t.LatestCompleted = false
	t.Hidden = false
	t.FirstReadAt = 0
	t.ReadWakeDelivered = false
	t.Revision++
}

func (t *Thread) Complete(execution string, at int64, foreground bool) {
	if t.LatestExecution != execution || t.LatestCompleted {
		return
	}
	t.LatestCompleted = true
	t.LastCompletedAt = at
	if foreground {
		t.markRead(at)
	}
	t.Revision++
}

func (t *Thread) markRead(at int64) {
	if t.LatestCompleted && t.FirstReadAt == 0 {
		t.FirstReadAt = at
		t.Revision++
	}
}

// ObserveVisit accepts cumulative foreground time, so retries cannot add the
// same interval twice. The caller supplies foreground only for a live visit.
func (t *Thread) ObserveVisit(id string, openedAt, foregroundMillis, at int64, foreground, searchOpen bool) {
	if foreground {
		t.markRead(at)
	}
	for i := range t.Visits {
		if t.Visits[i].ID != id {
			continue
		}
		if foregroundMillis > t.Visits[i].ForegroundMillis {
			t.Visits[i].ForegroundMillis = foregroundMillis
			t.Revision++
		}
		return
	}
	t.Visits = append(t.Visits, Visit{ID: id, OpenedAt: openedAt, ForegroundMillis: foregroundMillis})
	if searchOpen {
		t.Generation++
		t.Hidden = false
	}
	t.Revision++
}

func (t Thread) ReadWakeDue(now int64) bool {
	return !t.Hidden && t.FirstReadAt != 0 && !t.ReadWakeDelivered && now-t.FirstReadAt >= ReadDelay.Milliseconds()
}

// Hide applies only to the facts that the model saw. The caller rechecks
// enablement in the same transaction as this state transition.
func (t *Thread) Hide(expected uint64) bool {
	if t.Hidden || t.Revision != expected {
		return false
	}
	t.Hidden = true
	t.Revision++
	return true
}

func CrossedThreshold(previous, current int) bool {
	return previous < VisibleThreshold && current >= VisibleThreshold
}

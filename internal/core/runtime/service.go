package runtime

import (
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// The same gate protects the draining decision and every native admission.
// Holding an admission through its durable projection closes the gap where a
// draining observer could otherwise mistake accepted work for an idle host.
func (r *Runtime) beginServiceAdmission(continuation bool) (func(), error) {
	r.serviceMu.Lock()
	if r.serviceDraining && !continuation {
		r.serviceMu.Unlock()
		return nil, model.NewError("SERVICE_DRAINING", "The host is waiting to restart; finish current work or cancel the restart before starting a task")
	}
	r.serviceAdmissions++
	r.serviceMu.Unlock()
	var once sync.Once
	return func() { once.Do(func() { r.serviceMu.Lock(); r.serviceAdmissions--; r.serviceMu.Unlock() }) }, nil
}

func (r *Runtime) SetServiceDraining(draining bool) error {
	r.serviceMu.Lock()
	r.serviceDraining = draining
	r.serviceMu.Unlock()
	return nil
}

func (r *Runtime) serviceDrainPending() bool {
	r.serviceMu.Lock()
	defer r.serviceMu.Unlock()
	return r.serviceDraining
}

func (r *Runtime) ServiceActivity() (model.RuntimeServiceActivity, error) {
	r.serviceMu.Lock()
	defer r.serviceMu.Unlock()
	activity := model.RuntimeServiceActivity{Admissions: r.serviceAdmissions}
	snapshot := r.config.Store.Snapshot()
	count := func(record model.SessionRecord) {
		if execution := record.Observation.LatestExecution; execution != nil && !execution.Terminal() {
			activity.ActiveTasks++
		} else if record.Observation.BackgroundWork != nil || record.PendingInput {
			activity.ActiveTasks++
		}
	}
	for _, key := range snapshot.Keys("thread:") {
		var record model.ThreadRecord
		if _, err := snapshot.Get(key, &record); err != nil {
			return activity, err
		}
		count(record.SessionRecord)
	}
	for _, key := range snapshot.Keys("private-session:") {
		var session plugin.PrivateSessionSnapshot
		if _, err := snapshot.Get(key, &session); err != nil {
			return activity, err
		}
		count(session.Record)
	}
	if r.ServiceVoiceActive() {
		activity.ActiveVoice = 1
	}
	return activity, nil
}

package runtime

import (
	"context"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// The same gate protects the draining decision and every native admission.
// Holding an admission through its durable projection closes the gap where a
// draining observer could otherwise mistake accepted work for an idle host.
// A configuration admission is an ordinary service admission whose command may
// itself need to apply a pending Moku host change. The token lets the change
// gate exclude that command's own admission; unrelated concurrent admissions
// still block the change.
type serviceAdmissionToken struct{}

type serviceAdmissionContextKey struct{}

func (r *Runtime) beginServiceAdmission(continuation bool) (func(), error) {
	release, _, err := r.admitService(continuation, false)
	return release, err
}

// beginConfigurationAdmission marks the returned context with this admission so
// a host change started by the same command is not rejected by its own claim.
func (r *Runtime) beginConfigurationAdmission(ctx context.Context, continuation bool) (context.Context, func(), error) {
	release, token, err := r.admitService(continuation, true)
	if err != nil {
		return ctx, nil, err
	}
	return context.WithValue(ctx, serviceAdmissionContextKey{}, token), release, nil
}

func (r *Runtime) admitService(continuation, configuration bool) (func(), *serviceAdmissionToken, error) {
	r.serviceMu.Lock()
	if r.mokuHarnessChanging {
		r.serviceMu.Unlock()
		return nil, nil, model.NewError("MOKU_HARNESS_CHANGING", "Moku's harness is changing; retry after the switch completes")
	}
	if r.serviceDraining && !continuation {
		r.serviceMu.Unlock()
		return nil, nil, model.NewError("SERVICE_DRAINING", "The host is waiting to restart; finish current work or cancel the restart before starting a task")
	}
	r.serviceAdmissions++
	var token *serviceAdmissionToken
	if configuration {
		token = &serviceAdmissionToken{}
		r.configurationAdmissions[token] = struct{}{}
	}
	r.serviceMu.Unlock()
	var once sync.Once
	release := func() {
		once.Do(func() {
			r.serviceMu.Lock()
			if token != nil {
				delete(r.configurationAdmissions, token)
			}
			r.serviceAdmissions--
			r.serviceMu.Unlock()
		})
	}
	return release, token, nil
}

// VoicePreparationContext derives a Moku-lifetime preparation context that
// keeps this command's admission identity. Voice preparation can adopt a saved
// host preference; that replacement must not be rejected by the preparing
// command's own admission.
func (r *Runtime) VoicePreparationContext(service, command context.Context) context.Context {
	token, ok := command.Value(serviceAdmissionContextKey{}).(*serviceAdmissionToken)
	if !ok {
		return service
	}
	return context.WithValue(service, serviceAdmissionContextKey{}, token)
}

// Reserve the existing native admission boundary without holding its mutex
// across native cleanup. A queued Moku input may trigger the idle replacement;
// it will be sent to the new owner only after the replacement commits.
func (r *Runtime) beginMokuHarnessChange(ctx context.Context, allowMokuInput bool) (func(), error) {
	r.serviceMu.Lock()
	defer r.serviceMu.Unlock()
	busy := model.NewError("MOKU_HARNESS_BUSY", "Finish active Agent Threads and Moku work before changing Moku's harness")
	admissions := r.serviceAdmissions
	if token, ok := ctx.Value(serviceAdmissionContextKey{}).(*serviceAdmissionToken); ok {
		if _, held := r.configurationAdmissions[token]; held {
			admissions--
		}
	}
	if r.mokuHarnessChanging || admissions != 0 {
		return nil, busy
	}
	snapshot := r.config.Store.Snapshot()
	for _, key := range snapshot.Keys("thread:") {
		var thread model.ThreadRecord
		if _, err := snapshot.Get(key, &thread); err != nil {
			return nil, err
		}
		if thread.MokuHistory {
			continue
		}
		if execution := thread.Observation.LatestExecution; execution != nil && !execution.Terminal() {
			return nil, busy
		}
		if thread.Observation.BackgroundWork != nil || thread.PendingInput && (!thread.Moku || !allowMokuInput) {
			return nil, busy
		}
	}
	r.mokuHarnessChanging = true
	return func() {
		r.serviceMu.Lock()
		r.mokuHarnessChanging = false
		r.serviceMu.Unlock()
	}, nil
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
	if r.mokuHarnessChanging {
		activity.Admissions++
	}
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

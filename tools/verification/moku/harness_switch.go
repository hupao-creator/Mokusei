package main

import (
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	runtimepkg "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
)

type replayNamedHarness struct {
	plugin.Harness
	id string
}

func (h replayNamedHarness) Descriptor() plugin.HarnessDescriptor {
	descriptor := h.Harness.Descriptor()
	descriptor.ID = h.id
	return descriptor
}

func runHarnessSwitchReplay() error {
	for _, replay := range []func(*replaySystem){replayBusyHarnessSwitch, replayNoteHarnessSwitch} {
		func() {
			root, err := os.MkdirTemp("", "mokusei-harness-switch-")
			mokuReplayMust(err)
			defer os.RemoveAll(root)
			h := &replayNativeHarness{nativeModel: "first-model", wake: make(chan struct{}, 128)}
			s := startReplaySystemWithHarnesses(root, h, map[string]plugin.Harness{
				"mock": h, "other": replayNamedHarness{Harness: h, id: "other"},
			})
			defer s.close()
			mokuReplayMust(saveReplayHost(s, "mock"))
			mokuReplayMust(s.c.Submit(mokuReplayContext(), mokuReplayText("initial Moku work")))
			h.awaitTools(1)
			replay(s)
		}()
	}
	return nil
}

func saveReplayHost(s *replaySystem, host string) error {
	return saveReplayHostRuntime(s.r, host)
}

func saveReplayHostRuntime(r *runtimepkg.Runtime, host string) error {
	settings, revision, err := r.Settings()
	if err != nil {
		return err
	}
	settings.Moku.HostHarnessPreference = host
	result, err := r.UpdateSettings(mokuReplayContext(), revision, settings)
	if err == nil && result.Status != "saved" {
		return errors.New("Harness selection conflicted")
	}
	return err
}

func expectHarnessError(err error, code string) {
	var failure *model.Error
	mokuReplayCheck(errors.As(err, &failure) && failure.Code == code, fmt.Sprintf("expected %s, got %v", code, err))
}

func replayBusyHarnessSwitch(s *replaySystem) {
	_, before, err := s.r.Settings()
	mokuReplayMust(err)
	expectHarnessError(saveReplayHost(s, "other"), "MOKU_HARNESS_BUSY")
	settings, after, err := s.r.Settings()
	mokuReplayMust(err)
	mokuReplayCheck(before == after && settings.Moku.HostHarnessPreference == "mock", "busy host selection changed saved settings")
	settings.Moku.RoutingGuidance = mokuReplayString("keep unrelated edits available")
	_, err = s.r.UpdateSettings(mokuReplayContext(), after, settings)
	mokuReplayMust(err)
	mokuReplayMust(s.c.Cancel(mokuReplayContext()))

	child, err := s.r.CreateThread(mokuReplayContext(), runtimepkg.CreateThreadRequest{
		HarnessID: "mock", Cwd: s.root, Input: mokuReplayText("ordinary task").Input,
	})
	mokuReplayMust(err)
	expectHarnessError(saveReplayHost(s, "other"), "MOKU_HARNESS_BUSY")
	s.h.mu.Lock()
	native := s.h.handles[len(s.h.handles)-1]
	s.h.mu.Unlock()
	observation := native.open.ReadThread().Observation
	observation.LatestExecution.Status = "waiting-for-user"
	observation.LatestExecution.Interactions = []model.PublicInteraction{{
		ID: "approval", Kind: "permission", Title: "Approve task", Actions: []model.PublicInteractionAction{{ID: "approve", Intent: "allow", Label: "Approve"}}, Questions: []model.PublicInteractionQuestion{},
	}}
	mokuReplayMust(native.open.SessionState.Commit(mokuReplayContext(), mokuReplayRaw(observation)))
	expectHarnessError(saveReplayHost(s, "other"), "MOKU_HARNESS_BUSY")
	now := time.Now().UnixMilli()
	observation.LatestExecution.Status = "completed"
	observation.LatestExecution.FinishedAt = &now
	observation.LatestExecution.Interactions = nil
	observation.BackgroundWork = &model.PublicBackgroundWork{Status: "running"}
	mokuReplayMust(native.open.SessionState.Commit(mokuReplayContext(), mokuReplayRaw(observation)))
	// Let the real completion notification reach Moku, then leave only the
	// child's native background work active before checking that boundary.
	s.h.awaitTools(2)
	mokuReplayMust(s.c.Cancel(mokuReplayContext()))
	expectHarnessError(saveReplayHost(s, "other"), "MOKU_HARNESS_BUSY")
	observation.BackgroundWork = nil
	mokuReplayMust(native.open.SessionState.Commit(mokuReplayContext(), mokuReplayRaw(observation)))
	_, release, err := s.r.ClaimThreadInput(mokuReplayContext(), child.Record.ID)
	mokuReplayMust(err)
	expectHarnessError(saveReplayHost(s, "other"), "MOKU_HARNESS_BUSY")
	release()

	mokuReplayMust(saveReplayHost(s, "other"))
	_, err = s.r.SendThread(mokuReplayContext(), child.Record.ID, mokuReplayText("work after the settings save").Input)
	mokuReplayMust(err)
	old := s.record()
	expectHarnessError(s.c.Submit(mokuReplayContext(), mokuReplayText("must not switch while the child runs")), "MOKU_HARNESS_BUSY")
	mokuReplayCheck(s.record().ID == old.ID && s.record().HarnessID == "mock", "busy replacement changed the Moku owner")
	fmt.Println("PASS Harness changes reject Moku, running/waiting/pending/background tasks and work admitted after settings save")
}

func replayNoteHarnessSwitch(s *replaySystem) {
	old := s.record()
	note, err := s.r.UpdateMokuNote(mokuReplayContext(), old.ID, "# Next\n- Preserve this decision", nil)
	mokuReplayMust(err)
	mokuReplayCheck(note.OK, "note was not committed")
	mokuReplayMust(s.c.Cancel(mokuReplayContext()))
	mokuReplayMust(saveReplayHost(s, "other"))

	entered, release := make(chan struct{}), make(chan struct{})
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	s.h.mu.Lock()
	s.h.beforeClose = func(id string) error {
		if id != old.ID {
			return nil
		}
		close(entered)
		select {
		case <-release:
			return nil
		case <-mokuReplayContext().Done():
			return mokuReplayContext().Err()
		}
	}
	s.h.mu.Unlock()
	done := make(chan error, 1)
	go func() { done <- s.c.Submit(mokuReplayContext(), mokuReplayText("continue with the new Harness")) }()
	mokuReplayAwait("old Harness cleanup", entered)
	activity, err := s.r.ServiceActivity()
	mokuReplayMust(err)
	mokuReplayCheck(activity.Admissions > 0, "service restart readiness ignored the ongoing Harness replacement")
	child, err := s.r.CreateThread(mokuReplayContext(), runtimepkg.CreateThreadRequest{
		HarnessID: "mock", Cwd: s.root, Input: mokuReplayText("concurrent task").Input,
	})
	expectHarnessError(err, "MOKU_HARNESS_CHANGING")
	mokuReplayCheck(child.Record.ID == "", "rejected creation left a new Thread during Harness replacement")
	close(release)
	mokuReplayWaitError("idle Harness replacement", done)
	s.h.awaitTools(2)
	s.h.mu.Lock()
	s.h.beforeClose = nil
	input := s.h.inputs[len(s.h.inputs)-1]
	s.h.mu.Unlock()
	current := s.record()
	mokuReplayCheck(current.ID != old.ID && current.HarnessID == "other", "idle replacement did not select the new Harness")
	mokuReplayCheck(input.threadID == current.ID && noteContext(input.context) == moku.MokuNoteContext(note.State), "new Harness input lost the previous note state")
	mokuReplayCheck(current.Note != nil && current.Note.ID == note.State.Note.ID && current.Note.Text == note.State.Note.Text, "replacement did not preserve the note")
	archive, err := s.r.Thread(old.ID)
	mokuReplayMust(err)
	mokuReplayCheck(archive.MokuHistory && archive.Note == nil, "replacement did not retain read-only history separately from the note")

	mokuReplayMust(s.c.Cancel(mokuReplayContext()))
	empty, err := s.r.UpdateMokuNote(mokuReplayContext(), current.ID, "", model.SnapshotNote(current.Note).Basis)
	mokuReplayMust(err)
	mokuReplayCheck(empty.OK, "note clear failed")
	mokuReplayMust(saveReplayHost(s, "mock"))
	mokuReplayMust(s.c.Submit(mokuReplayContext(), mokuReplayText("switch back with an empty note")))
	s.h.awaitTools(3)
	s.h.mu.Lock()
	input = s.h.inputs[len(s.h.inputs)-1]
	mokuSends := s.h.nativeSends
	s.h.mu.Unlock()
	mokuReplayCheck(s.record().HarnessID == "mock" && noteContext(input.context) == moku.MokuNoteContext(empty.State), "empty note was lost or regenerated on switch back")
	mokuReplayCheck(mokuSends == 3, "Harness switching submitted extra model work")
	_, err = s.r.CreateThread(mokuReplayContext(), runtimepkg.CreateThreadRequest{
		HarnessID: "mock", Cwd: s.root, Input: mokuReplayText("retry after switching").Input,
	})
	mokuReplayMust(err)
	fmt.Println("PASS cross-Harness inputs inherit exact and empty notes, retain read-only history and fence concurrent native admission without extra model calls")
}

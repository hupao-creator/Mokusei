package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

// The native launcher mounts the production note body and sends its real
// viewport receipt over the authenticated client. The next native Moku input
// proves the committed exact text reached context, not just a Swift fixture.
func runSwiftNoteExposureReplay() (failure error) {
	root, err := os.MkdirTemp("", "mokusei-swift-note-exposure-")
	if err != nil {
		return err
	}
	defer func() { failure = errors.Join(failure, os.RemoveAll(root)) }()
	h := &replayNativeHarness{nativeModel: "first-model", wake: make(chan struct{}, 128)}
	s := startReplaySystem(root, h)
	defer s.close()
	initial := s.record()
	const text = "# Note exposure\n\n- Keep the approved direction\n- Review the deliverable"
	updated, err := s.r.UpdateMokuNote(mokuReplayContext(), initial.ID, text, nil)
	if err != nil {
		return err
	}
	if !updated.OK || updated.State.Note == nil {
		return errors.New("fixture note was not committed")
	}
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(root, "data"), HomeDir: root})
	if err != nil {
		return err
	}
	owner, err := profile.Acquire(p)
	if err != nil {
		return err
	}
	defer func() { failure = errors.Join(failure, owner.Release()) }()
	server, err := transport.Start(transport.Options{Profile: p, Epoch: owner.Epoch, Host: s.r})
	if err != nil {
		return err
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		failure = errors.Join(failure, server.Close(ctx), server.Finish(ctx))
	}()
	if err := profile.PublishConnection(p, server.Connection); err != nil {
		return err
	}
	command := exec.CommandContext(mokuReplayContext(), "python3", "tools/verification/moku-note/run.py", "--skip-build", "--exposure-connection", p.DataDir)
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	command.Cancel = func() error { return command.Process.Signal(os.Interrupt) }
	command.WaitDelay = 10 * time.Second
	if err := command.Run(); err != nil {
		return fmt.Errorf("Swift note exposure launcher: %w", err)
	}
	committed, err := s.r.Thread(initial.ID)
	if err != nil {
		return err
	}
	if committed.Note == nil || committed.Note.LastExposure == nil || committed.Note.LastExposure.Text != text || committed.Note.LastExposure.Revision != updated.State.Note.Revision || committed.Note.ReadingRevision != 1 {
		return errors.New("Swift receipt did not durably record the exact note version")
	}
	if err := s.c.Submit(mokuReplayContext(), mokuReplayText("continue after note exposure")); err != nil {
		return err
	}
	h.mu.Lock()
	inputs := append([]replayNativeInput(nil), h.inputs...)
	h.mu.Unlock()
	found := false
	for _, input := range inputs {
		if input.threadID != initial.ID {
			continue
		}
		for _, entry := range input.context {
			if entry.ID != "moku-note" {
				continue
			}
			_, raw, ok := strings.Cut(entry.Content, "\n")
			if !ok {
				continue
			}
			var state model.NoteState
			if json.Unmarshal([]byte(raw), &state) == nil && state.Basis != nil && state.Basis.ReadingRevision == 1 && state.Note != nil && state.Note.Text == text && state.LastExposure != nil && state.LastExposure.Text == text && state.LastExposure.Signal == model.NoteExposureSignal {
				found = true
			}
		}
	}
	if !found {
		return errors.New("committed Swift exposure was absent from the next Moku context")
	}
	fmt.Println("PASS production Swift viewport receipt -> authenticated Runtime -> exact persisted note -> Moku context")
	return nil
}

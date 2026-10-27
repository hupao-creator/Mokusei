// Package discussioncheck exercises real Harness discussions through the shared
// relay composition. Only media is synthetic; native CLI/model wire is external.
package discussioncheck

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/services/threadvoice"
)

func Run(ctx context.Context, preparer plugin.DiscussionPreparer, request plugin.DiscussionRequest, verify func(private bool) error, holding <-chan struct{}) error {
	request.Instructions = threadvoice.DiscussionInstructions
	relay := &media{speech: make(chan plugin.VoiceSpeech, 4)}
	var backend plugin.Discussion
	session, err := threadvoice.PrepareDiscussion(ctx, relay, func(ctx context.Context) (plugin.Discussion, error) {
		var err error
		backend, err = preparer.PrepareDiscussion(ctx, request)
		return backend, err
	})
	if err != nil {
		return fmt.Errorf("prepare discussion: %w", err)
	}
	defer session.Stop(context.Background())
	if err = verify(true); err != nil {
		return err
	}
	for i, marker := range []string{"DISCUSSION_FIRST", "DISCUSSION_SECOND", "DISCUSSION_ATTACK"} {
		relay.delegate(plugin.VoiceDelegation{ID: fmt.Sprint(i), Text: marker, Generation: int64(i)})
		select {
		case speech := <-relay.speech:
			expected := []string{"discussion-first-canary", "discussion-second-canary", "discussion-attack-blocked"}[i]
			if speech.Text != expected || speech.DelegationID != fmt.Sprint(i) || speech.Generation != int64(i) {
				return fmt.Errorf("discussion relay answer %d: %+v", i, speech)
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	// Concurrent delegations must serialize native runs without losing history.
	results := make(chan error, 2)
	for range 2 {
		go func() {
			text, err := backend.Ask(ctx, "DISCUSSION_SECOND concurrent")
			if err == nil && text != "discussion-second-canary" {
				err = fmt.Errorf("concurrent answer: %q", text)
			}
			results <- err
		}()
	}
	for range 2 {
		if err := <-results; err != nil {
			return err
		}
	}
	cancelled, cancelWaiting := context.WithCancel(ctx)
	cancelWaiting()
	if _, err := backend.Ask(cancelled, "must not dispatch"); !errors.Is(err, context.Canceled) {
		return fmt.Errorf("cancelled Ask dispatched: %v", err)
	}
	relay.delegate(plugin.VoiceDelegation{ID: "cancel", Text: "DISCUSSION_CANCEL"})
	select {
	case <-holding:
	case <-ctx.Done():
		return ctx.Err()
	}
	if err = session.Stop(ctx); err != nil {
		return err
	}
	if err = session.Stop(ctx); err != nil {
		return err
	}
	if err = verify(false); err != nil {
		return err
	}
	// Preparation failure must prevent microphone/media preparation entirely.
	relay = &media{speech: make(chan plugin.VoiceSpeech, 1)}
	invalid := request
	invalid.Source.SessionState = nil
	if _, err = threadvoice.PrepareDiscussion(ctx, relay, func(ctx context.Context) (plugin.Discussion, error) { return preparer.PrepareDiscussion(ctx, invalid) }); err == nil || relay.prepared {
		return errors.New("missing history admitted discussion media")
	}
	// Media startup failure must dispose an already prepared private branch.
	relay.prepareError = errors.New("fixture media preparation failure")
	if _, err = threadvoice.PrepareDiscussion(ctx, relay, func(ctx context.Context) (plugin.Discussion, error) { return preparer.PrepareDiscussion(ctx, request) }); !errors.Is(err, relay.prepareError) {
		return fmt.Errorf("media failure lost: %v", err)
	}
	if err = verify(false); err != nil {
		return err
	}
	// Provider/transport failure is returned by Ask and remains audible/readable
	// via the existing relay error path (not replaced with a fabricated answer).
	relay = &media{speech: make(chan plugin.VoiceSpeech, 1)}
	session, err = threadvoice.PrepareDiscussion(ctx, relay, func(ctx context.Context) (plugin.Discussion, error) { return preparer.PrepareDiscussion(ctx, request) })
	if err != nil {
		return err
	}
	defer session.Stop(context.Background())
	relay.delegate(plugin.VoiceDelegation{ID: "failure", Text: "DISCUSSION_FAILURE"})
	select {
	case speech := <-relay.speech:
		if !strings.HasPrefix(speech.Text, "本次讨论未能完成：") || !strings.Contains(speech.Text, "fixture discussion provider failure") {
			return fmt.Errorf("native failure not propagated: %q", speech.Text)
		}
	case <-ctx.Done():
		return ctx.Err()
	}
	if err = session.Stop(ctx); err != nil {
		return err
	}
	if err = verify(false); err != nil {
		return err
	}
	// Caller lifetime cancellation also owns cleanup without a separate UI stop.
	life, cancel := context.WithCancel(ctx)
	backend, err = preparer.PrepareDiscussion(life, request)
	if err != nil {
		cancel()
		return err
	}
	cancel()
	done := make(chan error, 1)
	go func() { done <- backend.Close() }()
	select {
	case err = <-done:
	case <-time.After(10 * time.Second):
		return errors.New("discussion cancellation cleanup stuck")
	}
	if err != nil {
		return err
	}
	return verify(false)
}

type media struct {
	plugin.VoiceSession
	mu           sync.Mutex
	closed       bool
	prepared     bool
	delegate     func(plugin.VoiceDelegation)
	speech       chan plugin.VoiceSpeech
	prepareError error
}

func (m *media) PrepareVoice(_ context.Context, instructions string) (plugin.VoiceSession, error) {
	if !strings.Contains(instructions, "Delegate every substantive question") {
		return nil, errors.New("relay contract missing")
	}
	m.prepared = true
	return m, m.prepareError
}
func (m *media) Closed() bool                                       { m.mu.Lock(); defer m.mu.Unlock(); return m.closed }
func (m *media) OnClose(func()) func()                              { return func() {} }
func (m *media) OnDelegation(f func(plugin.VoiceDelegation)) func() { m.delegate = f; return func() {} }
func (m *media) Speak(ctx context.Context, s plugin.VoiceSpeech) error {
	select {
	case m.speech <- s:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (m *media) Stop(context.Context) error { m.mu.Lock(); m.closed = true; m.mu.Unlock(); return nil }

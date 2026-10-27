package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"regexp"
	"sync"
	"unicode/utf16"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/services/threadvoice"
)

var voiceUUID = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func (r *Runtime) threadVoiceChannel(ctx context.Context, channel string, raw json.RawMessage) (any, error) {
	var outer map[string]json.RawMessage
	if err := json.Unmarshal(raw, &outer); err != nil {
		return nil, err
	}
	if len(outer) != 2 || outer["threadId"] == nil || outer["request"] == nil {
		return nil, errors.New("invalid thread voice envelope")
	}
	var action map[string]json.RawMessage
	if err := json.Unmarshal(outer["request"], &action); err != nil {
		return nil, err
	}
	var kind string
	if err := json.Unmarshal(action["action"], &kind); err != nil {
		return nil, err
	}
	fields := map[string][]string{"prepare": {"action", "requestId"}, "start": {"action", "sessionId", "ownershipId", "sdp"}, "stop": {"action", "sessionId", "ownershipId"}, "poll": {"action", "sessionId", "ownershipId", "after"}, "heartbeat": {"action", "sessionId", "ownershipId"}, "history": {"action"}}[kind]
	if fields == nil || len(action) != len(fields) {
		return nil, errors.New("invalid thread voice action fields")
	}
	for _, key := range fields {
		if action[key] == nil || bytes.Equal(bytes.TrimSpace(action[key]), []byte("null")) {
			return nil, errors.New("missing thread voice field")
		}
	}
	readOnly := kind == "poll" || kind == "history" || kind == "heartbeat"
	if (channel == "thread:voice-events") != readOnly {
		return nil, errors.New("voice action is not permitted on this command channel")
	}
	for _, key := range []string{"requestId", "sessionId", "ownershipId"} {
		if value := action[key]; value != nil {
			var id string
			if json.Unmarshal(value, &id) != nil || !voiceUUID.MatchString(id) {
				return nil, errors.New("voice identity must be a UUID")
			}
		}
	}
	return r.threadVoice(ctx, raw)
}

func (r *Runtime) voiceManager() *threadvoice.Manager {
	r.voiceOnce.Do(func() {
		r.voice = threadvoice.New(r.ctx, filepath.Join(r.config.DataDir, "voice-transcripts"), r.voiceSource)
	})
	return r.voice
}
func (r *Runtime) threadVoice(ctx context.Context, raw json.RawMessage) (any, error) {
	var request threadvoice.Request
	if err := model.Unmarshal(raw, &request); err != nil {
		return nil, err
	}
	if err := identifier(request.ThreadID); err != nil {
		return nil, err
	}
	a := request.Request
	switch a.Action {
	case "history":
	case "prepare":
		if err := identifier(a.RequestID); err != nil {
			return nil, err
		}
	case "start":
		if err := identifier(a.SessionID); err != nil {
			return nil, err
		}
		if a.SDP == "" || len(utf16.Encode([]rune(a.SDP))) > 128000 {
			return nil, errors.New("invalid voice SDP")
		}
	case "stop", "heartbeat":
		if err := identifier(a.SessionID); err != nil {
			return nil, err
		}
	case "poll":
		if err := identifier(a.SessionID); err != nil {
			return nil, err
		}
		if a.After < 0 || a.After > 9007199254740991 {
			return nil, errors.New("invalid voice event cursor")
		}
	default:
		return nil, errors.New("invalid thread voice action")
	}
	if err := r.begin(); err != nil {
		return nil, err
	}
	defer r.operations.Done()
	if a.Action == "prepare" || a.Action == "start" {
		release, err := r.beginServiceAdmission(false)
		if err != nil {
			return nil, err
		}
		defer release()
	}
	return r.voiceManager().Command(ctx, request)
}
func (r *Runtime) voiceSource(ctx context.Context, id string) (threadvoice.Source, error) {
	thread, err := r.Thread(id)
	if err != nil {
		return threadvoice.Source{}, err
	}
	if thread.Moku {
		return threadvoice.Source{}, errors.New("Moku is not an ordinary thread discussion target")
	}
	h, err := r.harness(ctx, thread)
	if err != nil {
		// Disabling a Harness prevents new discussions, but does not hide its
		// existing transcript history.
		return threadvoice.Source{}, nil
	}
	_, canDiscuss := h.(plugin.DiscussionPreparer)
	var relay plugin.VoiceCapability
	for _, harnessID := range r.harnessIDs() {
		if r.config.DisabledHarnesses[harnessID] != "" {
			continue
		}
		if candidate, ok := r.config.Harnesses[harnessID].(plugin.VoiceCapability); ok {
			relay = candidate
			break
		}
	}
	supported := canDiscuss && relay != nil
	source := threadvoice.Source{Supported: supported, Available: supported && (thread.Archived == nil || !*thread.Archived)}
	source.Prepare = func(lifetime context.Context) (plugin.VoiceSession, error) {
		if err := r.operational(); err != nil {
			return nil, err
		}
		source, err := r.Thread(id)
		if err != nil {
			return nil, err
		}
		if source.Moku || source.Archived != nil && *source.Archived {
			return nil, errors.New("voice source thread unavailable")
		}
		paths := []string{source.Cwd}
		if source.Worktree != nil {
			paths = append(paths, source.Worktree.Cwd)
		}
		for _, path := range paths {
			if r.config.Workspaces != nil {
				got, e := r.config.Workspaces.Validate(lifetime, path)
				if e != nil {
					return nil, e
				}
				if got != path {
					return nil, errors.New("voice source workspace identity changed")
				}
			} else {
				got, e := filepath.EvalSymlinks(path)
				if e != nil {
					return nil, e
				}
				if got != path {
					return nil, errors.New("voice source workspace identity changed")
				}
			}
		}
		selected, err := r.harness(lifetime, source)
		if err != nil {
			return nil, err
		}
		preparer, ok := selected.(plugin.DiscussionPreparer)
		if !ok || relay == nil {
			return nil, errors.New("thread does not support read-only voice discussion")
		}
		cwd := source.Cwd
		if source.Worktree != nil {
			cwd = source.Worktree.Cwd
		}
		tools, closeTools, err := threadvoice.ProjectReadTools(cwd)
		if err != nil {
			return nil, err
		}
		media, err := threadvoice.PrepareDiscussion(lifetime, relay, func(c context.Context) (plugin.Discussion, error) {
			return preparer.PrepareDiscussion(c, plugin.DiscussionRequest{Source: source, Tools: tools, Instructions: threadvoice.DiscussionInstructions})
		})
		if err != nil {
			return nil, errors.Join(err, closeTools())
		}
		wrapped := &voiceWithTools{VoiceSession: media, closeTools: closeTools}
		if err = lifetime.Err(); err == nil {
			var current model.ThreadRecord
			current, err = r.Thread(id)
			if err == nil && (current.Archived != nil && *current.Archived || !sameVoiceSource(source, current)) {
				err = errors.New("source thread configuration changed during voice preparation")
			}
		}
		if err != nil {
			return nil, errors.Join(err, wrapped.Stop(context.Background()))
		}
		return wrapped, nil
	}
	return source, nil
}
func sameVoiceSource(a, b model.ThreadRecord) bool {
	if a.Cwd != b.Cwd || a.HarnessID != b.HarnessID || a.Moku != b.Moku || !bytes.Equal(a.Settings, b.Settings) || (a.Worktree == nil) != (b.Worktree == nil) {
		return false
	}
	if a.Worktree != nil && a.Worktree.Cwd != b.Worktree.Cwd {
		return false
	}
	return true
}

type voiceWithTools struct {
	plugin.VoiceSession
	closeTools func() error
	once       sync.Once
	err        error
}

func (v *voiceWithTools) Stop(ctx context.Context) error {
	v.once.Do(func() { v.err = errors.Join(v.VoiceSession.Stop(context.WithoutCancel(ctx)), v.closeTools()) })
	return v.err
}
func (r *Runtime) closeVoice(ctx context.Context) error { return r.voiceManager().Close(ctx) }
func (r *Runtime) clearVoice(ctx context.Context) error { return r.voiceManager().Clear(ctx) }
func (r *Runtime) endThreadVoice(ctx context.Context, id string) error {
	return r.voiceManager().End(ctx, id)
}
func (r *Runtime) removeThreadVoice(ctx context.Context, id string) error {
	return r.voiceManager().Remove(ctx, id)
}

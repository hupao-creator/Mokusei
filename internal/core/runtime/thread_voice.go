package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"regexp"

	"github.com/hupao-creator/Mokusei/internal/core/model"
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
	if a.Action == "prepare" || a.Action == "start" || a.Action == "heartbeat" {
		return nil, model.NewError("THREAD_VOICE_REMOVED", "线程内语音已移除，请在 Overview 使用全局 Moku 语音。 / Thread calls have been removed. Use global Moku voice in Overview.")
	}
	switch a.Action {
	case "history":
	case "stop":
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
	return r.voiceManager().Command(ctx, request)
}
func (r *Runtime) voiceSource(ctx context.Context, id string) (threadvoice.Source, error) {
	thread, err := r.Thread(id)
	if err != nil {
		return threadvoice.Source{}, err
	}
	if thread.Moku || thread.MokuHistory {
		return threadvoice.Source{}, errors.New("Moku is not an ordinary thread discussion target")
	}
	// Retained transcript history does not need a Harness, model discovery,
	// private fork or media preparation capability.
	return threadvoice.Source{Supported: false, Available: false}, nil
}

// Settings still retires any pre-existing discussion owner when its workspace
// or native configuration changes. Removing call admission does not skip cleanup.
func sameVoiceSource(a, b model.ThreadRecord) bool {
	if a.Cwd != b.Cwd || a.HarnessID != b.HarnessID || a.Moku != b.Moku || a.MokuHistory != b.MokuHistory || !bytes.Equal(a.Settings, b.Settings) || (a.Worktree == nil) != (b.Worktree == nil) {
		return false
	}
	return a.Worktree == nil || a.Worktree.Cwd == b.Worktree.Cwd
}

func (r *Runtime) closeVoice(ctx context.Context) error { return r.voiceManager().Close(ctx) }
func (r *Runtime) clearVoice(ctx context.Context) error { return r.voiceManager().Clear(ctx) }
func (r *Runtime) endThreadVoice(ctx context.Context, id string) error {
	return r.voiceManager().End(ctx, id)
}
func (r *Runtime) removeThreadVoice(ctx context.Context, id string) error {
	return r.voiceManager().Remove(ctx, id)
}

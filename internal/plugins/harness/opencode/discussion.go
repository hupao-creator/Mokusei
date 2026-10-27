package opencode

import (
	"context"
	"errors"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// discussion owns only its private native branch. Its process stays alive long
// enough to delete the branch even when the caller's lifetime is cancelled.
type discussion struct {
	runtime       *Runtime
	id            string
	ctx           context.Context
	cancel        context.CancelFunc
	processCancel context.CancelFunc
	gate          chan struct{}
	once          sync.Once
	closeErr      error
}

func (h *Harness) PrepareDiscussion(ctx context.Context, request plugin.DiscussionRequest) (_ plugin.Discussion, err error) {
	state, err := DecodeState(request.Source.SessionState)
	if err != nil {
		return nil, err
	}
	source := state.NativeSessionID
	pending := !state.NativeSessionCreated && state.NativeTranscript == nil && state.ForkSource != nil
	if !pending && (source == "" || !state.NativeSessionCreated && state.NativeTranscript == nil) {
		return nil, errors.New("OpenCode has no native history for discussion; complete a conversation first")
	}
	settings, err := NormalizeThreadSettings(request.Source.Settings)
	if err != nil {
		return nil, err
	}
	cwd := request.Source.Cwd
	if request.Source.Worktree != nil {
		cwd = request.Source.Worktree.Cwd
	}
	process, processCancel := context.WithCancel(context.WithoutCancel(ctx))
	stopStartup := context.AfterFunc(ctx, processCancel)
	runtime, err := h.launch(process, settings, cwd, true)
	stopStartup()
	if err != nil {
		processCancel()
		return nil, err
	}
	life, cancel := context.WithCancel(ctx)
	d := &discussion{runtime: runtime, ctx: life, cancel: cancel, processCancel: processCancel, gate: make(chan struct{}, 1)}
	defer func() {
		if err != nil {
			err = errors.Join(err, d.Close())
		}
	}()
	if err = ValidateRuntimeSettings(ctx, runtime, settings, true, nil, "exclusive"); err != nil {
		return nil, err
	}
	config := BridgeConfiguration{Injection: &plugin.Injection{Instructions: []string{request.Instructions}, Tools: &plugin.ToolInjection{Mode: "exclusive", Bindings: request.Tools}}, ContextEntries: state.NativeContextEntries,
		BeforeModel: func(signal context.Context, actual ModelRequest) error {
			return ValidateRuntimeSettings(signal, runtime, settings, true, &actual.Model, "exclusive")
		}}
	if pending {
		// An unmaterialized ordinary fork already owns a frozen native export. Import
		// it directly into OUR session; never materialize or advance the source Thread.
		d.id = NewSessionID()
		if err = runtime.ConfigureSession(ctx, d.id, config); err != nil {
			return nil, err
		}
		err = runtime.Request(ctx, "POST", "/api/experimental/session/import", importTranscript(state.ForkSource.Transcript, d.id, cwd, settings), nil)
		if err != nil {
			return nil, err
		}
	} else {
		// Registering bridge ownership does not write native source state. No model or
		// tool operation on the source is admitted through this process.
		deny := BridgeConfiguration{BeforeModel: func(context.Context, ModelRequest) error { return errors.New("source discussion session is read-only") }}
		if err = runtime.ConfigureSession(ctx, source, deny); err != nil {
			return nil, err
		}
		allocation, done := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		var info Object
		err = runtime.Request(allocation, "POST", sessionPath(source, "/fork"), Object{}, &info)
		done()
		if err != nil {
			return nil, err
		}
		id := str(info["id"])
		if !strings.HasPrefix(id, "ses_") || id == source || object(info["fork"])["sessionID"] != source {
			return nil, errors.New("OpenCode returned an unrelated discussion fork")
		}
		if !runtime.bridge.TrackChild(id, source) {
			return nil, errors.New("OpenCode discussion fork ownership unavailable")
		}
		d.id = id
		if err = runtime.ConfigureSession(ctx, id, config); err != nil {
			return nil, err
		}
	}
	if settings.Agent != "" {
		err = runtime.Request(ctx, "POST", sessionPath(d.id, "/agent"), Object{"agent": settings.Agent}, nil)
		if err != nil {
			return nil, err
		}
	}
	if model := settings.NativeModel(); model != nil {
		err = runtime.Request(ctx, "POST", sessionPath(d.id, "/model"), Object{"model": model}, nil)
		if err != nil {
			return nil, err
		}
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	go func() { <-life.Done(); _ = d.Close() }()
	return d, nil
}

func (d *discussion) Ask(ctx context.Context, question string) (answer string, err error) {
	if strings.TrimSpace(question) == "" {
		return "", errors.New("OpenCode discussion question is empty")
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(d.ctx, cancel)
	defer stop()
	select {
	case d.gate <- struct{}{}:
		defer func() { <-d.gate }()
	case <-ctx.Done():
		return "", ctx.Err()
	}
	if err = ctx.Err(); err != nil {
		return "", err
	}
	// An uncertain receipt or failed run must not contaminate a later question.
	defer func() {
		if err != nil {
			err = errors.Join(err, d.Close())
		}
	}()
	if err = d.runtime.Request(ctx, "POST", sessionPath(d.id, "/prompt"), Object{"id": newMessageID(), "text": "Current discussion question (do not continue the source task):\n\n" + question}, nil); err != nil {
		return "", err
	}
	if err = d.runtime.Request(ctx, "POST", "/api/experimental/session/"+url.PathEscape(d.id)+"/wait", nil, nil); err != nil {
		return "", err
	}
	snapshot, err := d.runtime.Snapshot(ctx, d.id)
	if err != nil {
		return "", err
	}
	var last Object
	for _, raw := range array(snapshot["messages"]) {
		if m := object(raw); m["type"] == "assistant" {
			last = m
		}
	}
	if object(snapshot["info"])["outcome"] != "succeeded" {
		return "", errors.New(nativeFailure(last["error"]))
	}
	answer = strings.TrimSpace(contentText(last["content"]))
	if answer == "" {
		return "", errors.New("OpenCode discussion returned no answer")
	}
	return answer, nil
}

func (d *discussion) Close() error {
	d.once.Do(func() {
		d.cancel()
		if d.id != "" {
			cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			// DELETE follows interrupt only on our owned private session.
			interrupt := d.runtime.Request(cleanup, "POST", sessionPath(d.id, "/interrupt?resume=false"), nil, nil)
			deleted := d.runtime.Request(cleanup, "DELETE", sessionPath(d.id, ""), nil, nil)
			cancel()
			d.closeErr = errors.Join(interrupt, deleted)
		}
		d.closeErr = errors.Join(d.closeErr, d.runtime.Close())
		d.processCancel()
	})
	return d.closeErr
}

var _ plugin.DiscussionPreparer = (*Harness)(nil)
var _ plugin.Discussion = (*discussion)(nil)

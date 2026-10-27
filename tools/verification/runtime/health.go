package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"reflect"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

func verifyHTTPHealth(ctx context.Context, r *core.Runtime, root, id string) (err error) {
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(root, "health-http"), HomeDir: root})
	if err != nil {
		return err
	}
	owner, err := profile.Acquire(p)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, owner.Release()) }()
	server, err := transport.Start(transport.Options{Profile: p, Epoch: "health-http-replay", Host: r})
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, server.Close(context.Background())) }()
	fork, err := verifyHealthPublicThread(ctx, server.Connection, id)
	if err != nil {
		return err
	}
	if err = r.DeleteThread(ctx, fork); err != nil {
		return err
	}
	fmt.Println("PASS health client through production HTTP/NDJSON/SQLite: continuation identity, detached read/source isolation, stale interaction rejection, interruption and independent fork")
	return nil
}

func verifyHealthPublicThread(ctx context.Context, connection profile.Connection, id string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	client := newRuntimeClient(ctx, connection)
	defer client.close()
	if err := client.start(); err != nil {
		return "", err
	}
	state, err := client.snapshot()
	if err != nil {
		return "", err
	}
	previous := ""
	for _, t := range state.Threads {
		if t.ID == id && t.Observation.LatestExecution != nil {
			previous = t.Observation.LatestExecution.ExecutionID
		}
	}
	if previous == "" {
		return "", errors.New("health HTTP fixture has no prior execution")
	}
	if _, err = healthWait(ctx, client, id, "", true); err == nil {
		return "", errors.New("health HTTP observer accepted interrupted source as completed")
	}
	if err = client.invoke(ctx, "thread:follow-up", []any{map[string]any{"threadId": id, "input": healthInput("HTTP health continuation")}}, nil); err != nil {
		return "", err
	}
	running, err := healthWait(ctx, client, id, previous, false)
	if err != nil {
		return "", err
	}
	if running.Observation.LatestExecution.Terminal() {
		return "", errors.New("controlled continuation not running")
	}
	var answer string
	if err = client.invoke(ctx, "thread:read", []any{map[string]any{"threadId": id, "question": "health isolated question"}}, &answer); err != nil {
		return "", err
	}
	if answer != "answer: health isolated question" {
		return "", fmt.Errorf("unexpected detached read: %q", answer)
	}
	if err = healthSourceUnchanged(client, running); err != nil {
		return "", err
	}
	if err = client.invoke(ctx, "thread:interaction-respond", []any{map[string]any{"threadId": id, "executionId": running.Observation.LatestExecution.ExecutionID, "interactionId": "stale-interaction", "actionId": "stale-action"}}, nil); err == nil {
		return "", errors.New("public runtime accepted stale interaction response")
	}
	if err = client.invoke(ctx, "thread:interrupt", []any{model.CancellationRequest{ThreadID: id, ExpectedCancellationID: running.CancellationID}}, nil); err != nil {
		return "", err
	}
	for {
		state, err = client.snapshot()
		if err != nil {
			return "", err
		}
		settled := false
		for _, t := range state.Threads {
			if t.ID == id && t.Observation.LatestExecution != nil && t.Observation.LatestExecution.ExecutionID == running.Observation.LatestExecution.ExecutionID && t.Observation.LatestExecution.Status == "interrupted" {
				settled = true
			}
		}
		if settled {
			break
		}
		if err = healthPause(ctx, time.Millisecond); err != nil {
			return "", err
		}
	}
	var fork struct {
		ThreadID string `json:"threadId"`
	}
	if err = client.invoke(ctx, "thread:fork", []any{map[string]any{"threadId": id, "request": map[string]any{}}}, &fork); err != nil {
		return "", err
	}
	if fork.ThreadID == "" || fork.ThreadID == id {
		return "", errors.New("public runtime fork is not independent")
	}
	return fork.ThreadID, nil
}

func healthWait(ctx context.Context, client *runtimeClient, id, previous string, terminal bool) (model.ThreadRecord, error) {
	for {
		state, err := client.snapshot()
		if err != nil {
			return model.ThreadRecord{}, err
		}
		for _, thread := range state.Threads {
			if thread.ID != id {
				continue
			}
			execution := thread.Observation.LatestExecution
			if execution == nil || execution.ExecutionID == previous {
				continue
			}
			if !terminal || execution.Terminal() {
				if terminal && execution.Status != "completed" {
					message := ""
					if execution.Error != nil {
						message = *execution.Error
					}
					return thread, fmt.Errorf("thread %s execution %s %s: %s", id, execution.ExecutionID, execution.Status, message)
				}
				return thread, nil
			}
			if len(execution.Interactions) > 0 {
				return thread, fmt.Errorf("thread %s requires an interaction; live smoke does not auto-approve", id)
			}
		}
		if err = healthPause(ctx, 25*time.Millisecond); err != nil {
			return model.ThreadRecord{}, err
		}
	}
}

func healthInput(prompt string) map[string]any {
	return map[string]any{"parts": []any{map[string]any{"kind": "text", "text": prompt}}}
}

func healthSourceUnchanged(client *runtimeClient, before model.ThreadRecord) error {
	state, err := client.snapshot()
	if err != nil {
		return err
	}
	for _, t := range state.Threads {
		if t.ID == before.ID {
			if !reflect.DeepEqual(t.Observation.LatestExecution, before.Observation.LatestExecution) || !healthJSONEqual(t.SessionState, before.SessionState) || !healthJSONEqual(t.Settings, before.Settings) || t.Cwd != before.Cwd || t.HarnessID != before.HarnessID {
				return errors.New("read/fork mutated source thread")
			}
			return nil
		}
	}
	return errors.New("source thread disappeared")
}

func healthJSONEqual(a, b json.RawMessage) bool {
	var left, right any
	if len(a) > 0 && json.Unmarshal(a, &left) != nil {
		return false
	}
	if len(b) > 0 && json.Unmarshal(b, &right) != nil {
		return false
	}
	return reflect.DeepEqual(left, right)
}

func healthPause(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

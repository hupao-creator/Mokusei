package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

// Exercise the public client envelope path: authenticated HTTP command ->
// Runtime admission/drain guard -> actual Moku strict parser -> controlled media.
// No native provider, microphone or audio device is involved.
func runPublicVoiceReplay(root string) error {
	factory := &voiceReplayFactory{}
	directory := filepath.Join(root, "public-voice-http")
	system := startVoiceReplay(directory, "codex", factory)
	defer func() { _ = system.close() }()
	profile, err := profile.Resolve(profile.Options{DataDir: directory, HomeDir: root})
	if err != nil {
		return err
	}
	server, err := transport.Start(transport.Options{Profile: profile, Epoch: "voice-public-fixture", Host: system.r})
	if err != nil {
		return err
	}
	defer func() { _ = server.Close(context.Background()); _ = server.Finish(context.Background()) }()
	client := &http.Client{Timeout: 10 * time.Second}
	defer client.CloseIdleConnections()
	invoke := func(channel string, fields map[string]any) (map[string]any, error) {
		id, err := transport.CreateCommandID()
		if err != nil {
			return nil, err
		}
		body, err := json.Marshal(map[string]any{"commandId": id, "args": []any{fields}})
		if err != nil {
			return nil, err
		}
		request, err := http.NewRequestWithContext(mokuReplayContext(), "POST", fmt.Sprintf("http://127.0.0.1:%d/invoke/%s", server.Connection.Port, channel), bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		request.Header.Set("Authorization", "Bearer "+server.Connection.Token)
		request.Header.Set("X-Mokusei-Epoch", server.Connection.Epoch)
		request.Header.Set("X-Mokusei-Protocol", fmt.Sprint(transport.ProtocolVersion))
		response, err := client.Do(request)
		if err != nil {
			return nil, err
		}
		defer response.Body.Close()
		var result transport.Result
		if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&result); err != nil {
			return nil, err
		}
		if !result.OK {
			if result.Error == nil {
				return nil, errors.New("public voice response omitted failure")
			}
			return nil, model.NewError(result.Error.Code, result.Error.Message)
		}
		if response.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("voice HTTP %d", response.StatusCode)
		}
		var value map[string]any
		if err := json.Unmarshal(result.Value, &value); err != nil {
			return nil, err
		}
		return value, nil
	}
	prepare := map[string]any{"action": "prepare", "requestId": voiceReplayRequestID}
	prepared, err := invoke("moku:voice", prepare)
	if err != nil {
		return fmt.Errorf("public prepare with requestId: %w", err)
	}
	session := factory.last()
	mokuReplayCheck(prepared["sessionId"] == session.ID() && prepared["ownershipId"] == voiceReplayRequestID, "public prepare lost voice identities")
	start := map[string]any{"action": "start", "sessionId": session.ID(), "ownershipId": voiceReplayRequestID, "sdp": "fixture-offer"}
	started, err := invoke("moku:voice", start)
	if err != nil {
		return fmt.Errorf("public start with SDP and ownership: %w", err)
	}
	mokuReplayCheck(started["sdp"] == "fixture-answer", "public start lost native SDP")
	heartbeat := map[string]any{"action": "heartbeat", "sessionId": session.ID(), "ownershipId": voiceReplayRequestID}
	stop := map[string]any{"action": "stop", "sessionId": session.ID(), "ownershipId": voiceReplayRequestID}
	poll := map[string]any{"action": "poll", "sessionId": session.ID(), "ownershipId": voiceReplayRequestID, "after": 0}
	_, err = invoke("moku:voice-events", heartbeat)
	if err != nil {
		return err
	}
	_, err = invoke("moku:voice-events", poll)
	if err != nil {
		return err
	}

	for _, test := range []struct {
		channel string
		fields  map[string]any
	}{
		{"moku:voice", prepare}, {"moku:voice", start}, {"moku:voice-events", heartbeat}, {"moku:voice", stop}, {"moku:voice-events", poll},
	} {
		invalid := map[string]any{}
		for key, value := range test.fields {
			invalid[key] = value
		}
		invalid["unexpected"] = true
		_, err := invoke(test.channel, invalid)
		var failure *model.Error
		mokuReplayCheck(errors.As(err, &failure) && failure.Code == "INVALID_REQUEST" && failure.Message == "Invalid voice command", "Runtime routing weakened the owning Moku voice envelope validator")
		mokuReplayCheck(!session.Closed(), "invalid public voice command changed media ownership")
	}
	for _, action := range []string{"start", "heartbeat", "stop"} {
		fields := map[string]any{"action": action, "sessionId": session.ID()}
		channel := "moku:voice"
		if action == "start" {
			fields["sdp"] = "fixture-offer"
		}
		if action == "heartbeat" {
			channel = "moku:voice-events"
		}
		_, err = invoke(channel, fields)
		var failure *model.Error
		mokuReplayCheck(errors.As(err, &failure) && failure.Code == "INVALID_REQUEST", "public voice accepted missing ownership identity")
	}
	mokuReplayMust(system.r.SetServiceDraining(true))
	for _, fields := range []map[string]any{{"action": "prepare", "requestId": voiceReplayInputID}, start} {
		_, err = invoke("moku:voice", fields)
		var failure *model.Error
		mokuReplayCheck(errors.As(err, &failure) && failure.Code == "SERVICE_DRAINING", "public voice admitted prepare/start while host was draining")
	}
	_, err = invoke("moku:voice-events", heartbeat)
	if err != nil {
		return err
	}
	_, err = invoke("moku:voice-events", poll)
	if err != nil {
		return err
	}
	_, err = invoke("moku:voice", stop)
	if err != nil {
		return err
	}
	mokuReplayCheck(session.Closed() && !system.r.ServiceVoiceActive(), "public stop during drain retained media")
	mokuReplayMust(system.r.SetServiceDraining(false))
	_, err = invoke("moku:voice", map[string]any{"action": "prepare", "requestId": voiceReplayInputID})
	if err != nil {
		return err
	}
	previous := factory.last()
	next, err := invoke("moku:voice", map[string]any{"action": "prepare", "requestId": voiceReplayRejectedInputID, "takeover": voiceReplayInputID})
	if err != nil {
		return fmt.Errorf("public prepare with explicit takeover: %w", err)
	}
	mokuReplayCheck(previous.Closed() && next["ownershipId"] == voiceReplayRejectedInputID, "public takeover lost its generation fence")
	_, err = invoke("moku:voice", map[string]any{"action": "stop", "sessionId": next["sessionId"], "ownershipId": voiceReplayRejectedInputID})
	if err != nil {
		return err
	}
	fmt.Println("PASS public HTTP -> Runtime -> Moku voice: prepare/requestId, start/SDP/ownership, heartbeat/poll/stop, strict unknown/missing fields, explicit takeover and host drain admission/cleanup")
	return nil
}

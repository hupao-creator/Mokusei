package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/tools/verification/swiftfixture"
)

// Fixed source/desired content is independent of both implementations. Only the
// patch comes from Go production code; Swift applies it without a replay decoder
// or an assertion about which valid diff strategy the producer must choose.
func verifySwiftDeltas() (failure error) {
	fixtures := []struct {
		Name   string          `json:"name"`
		Before json.RawMessage `json:"before"`
		After  json.RawMessage `json:"after"`
		Patch  any             `json:"patch"`
	}{
		{
			Name:   "UTF-16 prefix and suffix around changing astral text",
			Before: json.RawMessage(`{"text":"😀prefix🚀suffix🧭"}`),
			After:  json.RawMessage(`{"text":"😀prefix🛰️suffix🧭"}`),
		},
		{
			Name:   "nested edits survive insertion beside unchanged array tails",
			Before: json.RawMessage(`{"rows":[{"text":"left","deep":[0,1]},{"text":"stay"},{"text":"tail"}]}`),
			After:  json.RawMessage(`{"rows":[{"text":"changed🚀","deep":[1]},{"text":"inserted"},{"text":"stay"},{"text":"tail"}]}`),
		},
		{
			Name:   "deletion to an empty array",
			Before: json.RawMessage(`{"rows":[0,{"text":"removed"}]}`),
			After:  json.RawMessage(`{"rows":[]}`),
		},
		{
			Name:   "exact keys and absent versus null properties",
			Before: json.RawMessage(`{"\u00e9":"composed","e\u0301":"decomposed","__proto__":{"old":true},"constructor":1,"deleted":null,"kept":null}`),
			After:  json.RawMessage(`{"\u00e9":"new composed","e\u0301":"new decomposed","__proto__":{"replacement":2},"constructor":null,"added":null,"kept":null}`),
		},
		{
			Name:   "root replacement with an explicit null",
			Before: json.RawMessage(`{"rows":["old"]}`),
			After:  json.RawMessage(`null`),
		},
	}
	for i := range fixtures {
		before, err := model.Decode(fixtures[i].Before)
		if err != nil {
			return err
		}
		after, err := model.Decode(fixtures[i].After)
		if err != nil {
			return err
		}
		fixtures[i].Patch = transport.CreateJSONDelta(before, after)
	}
	data, err := json.Marshal(fixtures)
	if err != nil {
		return err
	}
	directory, err := os.MkdirTemp("", "mokusei-swift-deltas-")
	if err != nil {
		return err
	}
	defer func() { failure = errors.Join(failure, os.RemoveAll(directory)) }()
	path := filepath.Join(directory, "fixtures.json")
	if err = os.WriteFile(path, data, 0600); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	command := swiftfixture.Test(ctx, "--filter", "GoDeltaInteropTests")
	command.Env = append(os.Environ(), "MOKUSEI_GO_DELTA_FIXTURES="+path)
	var output bytes.Buffer
	command.Stdout = io.MultiWriter(os.Stdout, &output)
	command.Stderr = os.Stderr
	command.WaitDelay = 5 * time.Second
	if err = command.Run(); err != nil {
		return err
	}
	if !bytes.Contains(output.Bytes(), []byte(fmt.Sprintf("PASS Go delta fixtures: %d", len(fixtures)))) {
		return errors.New("native delta verification was skipped or did not execute all fixtures")
	}
	return nil
}

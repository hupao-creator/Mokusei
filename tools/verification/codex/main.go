// Command codex runs bounded, deterministic integration replays of the Codex
// adapter. It is also its own synthetic external CLI, so no JS/Python fixtures
// or model account are required.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/hupao-creator/Mokusei/tools/verification/firstresponse"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

type object = map[string]any

func record(v any) object {
	m, _ := v.(map[string]any)
	if m == nil {
		return object{}
	}
	return m
}
func text(v any) string { s, _ := v.(string); return s }
func list(v any) []any  { s, _ := v.([]any); return s }
func encoded(v any) json.RawMessage {
	b, e := json.Marshal(v)
	if e != nil {
		panic(e)
	}
	return b
}
func decoded(b []byte) object { m := object{}; _ = json.Unmarshal(b, &m); return m }
func check(ok bool, message string) error {
	if !ok {
		return fmt.Errorf("%s", message)
	}
	return nil
}

type memoryStore struct {
	mu      sync.Mutex
	state   json.RawMessage
	commits int
}

func (s *memoryStore) Read() json.RawMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append(json.RawMessage{}, s.state...)
}
func (s *memoryStore) Commit(_ context.Context, state json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.commits++
	s.state = append(json.RawMessage{}, state...)
	return nil
}
func (s *memoryStore) Count() int { s.mu.Lock(); defer s.mu.Unlock(); return s.commits }

func main() {
	if os.Getenv("MOKUSEI_CODEX_REPLAY_PEER") == "1" {
		if e := fixtureMain(); e != nil {
			fmt.Fprintln(os.Stderr, e)
			os.Exit(1)
		}
		return
	}
	if e := verificationMain(); e != nil {
		fail(e)
	}
}
func verificationMain() error {
	settingsPerformance := flag.Bool("settings-performance", false, "measure concurrent settings/defaults reads with the native fixture")
	streamOnly := flag.Bool("stream-only", false, "run only deterministic native streaming and cancellation replay")
	streamPerformance := flag.Bool("stream-performance", false, "measure real JSONL streaming without enforcing optimization thresholds")
	streamChunks := flag.Int("stream-chunks", 512, "chunks per stream performance sample (2..1024)")
	streamRepeats := flag.Int("stream-repeats", 3, "samples per stream kind (1..20)")
	settlementOnly := flag.Bool("settlement-only", false, "run only deterministic native/durable follow-up completion races")
	voiceOnly := flag.Bool("voice-only", false, "only replay native voice notifications and feedback identities without audio devices")
	voiceConfigurationOnly := flag.Bool("voice-configuration-only", false, "only replay native voice configuration rejection and cleanup ownership")
	realOnly := flag.Bool("real-only", false, "run only installed-CLI loopback verification (requires -real-codex)")
	real := flag.String("real-codex", "", "also verify this installed native Codex executable against a local scripted Provider (macOS only)")
	flag.Parse()
	if _, err := firstresponse.Verify("codex"); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Second)
	defer cancel()
	root, e := os.MkdirTemp("", "mokusei-codex-verification-")
	if e != nil {
		return e
	}
	defer os.RemoveAll(root)
	if *settingsPerformance {
		return verifySettingsPerformance(ctx, root)
	}
	if *voiceConfigurationOnly {
		binary, err := os.Executable()
		if err != nil {
			return err
		}
		return verifyVoiceConfiguration(ctx, filepath.Join(root, "voice-configuration"), binary)
	}
	if *streamOnly || *streamPerformance {
		binary, err := os.Executable()
		if err != nil {
			return err
		}
		if *streamPerformance {
			return runStreamPerformance(ctx, root, binary, *streamChunks, *streamRepeats)
		}
		return verifyStreaming(ctx, root, binary)
	}
	if *settlementOnly {
		binary, e := os.Executable()
		if e != nil {
			return e
		}
		return verifyFollowUpSettlement(ctx, root, binary)
	}
	if *realOnly {
		if *real == "" {
			return fmt.Errorf("-real-only requires -real-codex")
		}
		return runReal(ctx, filepath.Join(root, "real"), *real)
	}
	if *voiceOnly {
		return runSyntheticVoice(ctx, filepath.Join(root, "voice"))
	}
	if e = runSynthetic(ctx, filepath.Join(root, "synthetic")); e != nil {
		return e
	}
	if *real != "" {
		if e = runReal(ctx, filepath.Join(root, "real"), *real); e != nil {
			return e
		}
	}
	return nil
}
func fail(e error) { fmt.Fprintln(os.Stderr, "FAIL:", e); os.Exit(1) }
func isolatedEnvironment(root string) (map[string]string, error) {
	for _, dir := range []string{"home", "native-home", "tmp", "work", "harness"} {
		if e := os.MkdirAll(filepath.Join(root, dir), 0700); e != nil {
			return nil, e
		}
	}
	return map[string]string{"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": filepath.Join(root, "home"), "CODEX_HOME": filepath.Join(root, "native-home"), "CODEX_SQLITE_HOME": filepath.Join(root, "native-home"), "TMPDIR": filepath.Join(root, "tmp"), "LANG": "en_US.UTF-8", "NO_COLOR": "1"}, nil
}
func environmentList(values map[string]string) []string {
	result := []string{}
	for key, value := range values {
		result = append(result, key+"="+value)
	}
	return result
}
func host(root string, environment map[string]string) plugin.HostContext {
	return plugin.HostContext{HarnessDataRoot: filepath.Join(root, "harness"), TemporaryWorkspaceRoot: filepath.Join(root, "tmp"), Environment: func(context.Context) (map[string]string, error) {
		copy := map[string]string{}
		for k, v := range environment {
			copy[k] = v
		}
		return copy, nil
	}}
}
func awaitExecution(ctx context.Context, adapter *codex.Adapter, store *memoryStore, handle plugin.Handle, approve bool) (*model.PublicExecution, error) {
	for {
		observation, e := adapter.SessionState().Project(store.Read())
		if e != nil {
			return nil, e
		}
		current := observation.LatestExecution
		if current != nil {
			if current.Status == "waiting-for-user" && approve {
				if len(current.Interactions) != 1 {
					return nil, fmt.Errorf("expected one approval, got %d", len(current.Interactions))
				}
				if e := handle.Respond(ctx, model.RespondRequest{ExecutionID: "stale-execution", InteractionID: current.Interactions[0].ID, ActionID: "allow-once"}); e == nil {
					return nil, fmt.Errorf("stale execution answered Codex interaction")
				}
				if e := handle.Respond(ctx, model.RespondRequest{ExecutionID: current.ExecutionID, InteractionID: current.Interactions[0].ID, ActionID: "allow-once"}); e != nil {
					return nil, e
				}
				approve = false
			}
			if current.Terminal() {
				if current.Status != "completed" {
					message := ""
					if current.Error != nil {
						message = *current.Error
					}
					return nil, fmt.Errorf("execution ended %s: %s", current.Status, message)
				}
				return current, nil
			}
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(5 * time.Millisecond):
		}
	}
}

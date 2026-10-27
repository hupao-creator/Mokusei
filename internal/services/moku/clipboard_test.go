package moku

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func clipboardToolFixture(t *testing.T, reader clipboardReader) (plugin.ToolBinding, *model.ThreadRecord, *Coordinator) {
	t.Helper()
	record := &model.ThreadRecord{ID: "moku", Moku: true}
	record.Observation.LatestExecution = &model.PublicExecution{ExecutionID: "execution", Status: "running"}
	var mu sync.Mutex
	c := &Coordinator{
		readClipboardText: reader, running: true, ctx: context.Background(), id: record.ID,
		scopes: map[string]executionScope{"execution": {threadID: record.ID, ctx: context.Background()}},
		config: Configuration{
			Thread: func(string) (model.ThreadRecord, error) {
				mu.Lock()
				defer mu.Unlock()
				return *record, nil
			},
			UpdateThread: func(_ context.Context, _ string, update func(*model.ThreadRecord) error) error {
				mu.Lock()
				defer mu.Unlock()
				return update(record)
			},
		},
	}
	for _, binding := range c.tools(record.ID, ThreadCreationDescription{}) {
		if binding.Name == "read_clipboard" {
			return binding, record, c
		}
	}
	t.Fatal("read_clipboard binding missing")
	return plugin.ToolBinding{}, nil, nil
}

func TestClipboardSchemaAndAdmission(t *testing.T) {
	for _, tc := range []struct {
		args string
		max  int
	}{
		{`{}`, 4000}, {`{"maxCharacters":1}`, 1}, {`{"maxCharacters":20000}`, 20000},
		{`{"maxCharacters":2e1}`, 20}, {`{"maxCharacters":4.0}`, 4},
		{`{"maxCharacters":0}`, 0}, {`{"maxCharacters":-1}`, 0}, {`{"maxCharacters":20001}`, 0},
		{`{"maxCharacters":1.5}`, 0}, {`{"maxCharacters":null}`, 0}, {`{"maxCharacters":"4"}`, 0},
		{`{"text":"secret"}`, 0}, {`{"maxCharacters":4,"extra":true}`, 0}, {`[]`, 0},
	} {
		t.Run(tc.args, func(t *testing.T) {
			calls := 0
			binding, _, _ := clipboardToolFixture(t, func(ctx context.Context, maxBytes int) (clipboardText, error) {
				calls++
				if maxBytes != tc.max*4 {
					t.Fatalf("maxBytes = %d, want %d", maxBytes, tc.max*4)
				}
				deadline, ok := ctx.Deadline()
				if !ok || time.Until(deadline) > clipboardTimeout {
					t.Fatal("reader did not receive a bounded deadline")
				}
				return clipboardText{}, nil
			})
			_, err := binding.Execute(context.Background(), plugin.ToolCall{Arguments: json.RawMessage(tc.args)})
			if (err == nil) != (tc.max > 0) || (tc.max == 0 && calls != 0) {
				t.Fatalf("err = %v, reader calls = %d", err, calls)
			}
		})
	}
}

func TestClipboardTextAndTranscript(t *testing.T) {
	for _, tc := range []struct {
		name, text, want string
		max              int
		clipped          bool
		truncated        bool
	}{
		{"empty", "", "", 10, false, false},
		{"plain", " token\n", " token\n", 10, false, false},
		{"unicode", "中文🙂suffix", "中文🙂", 3, false, true},
		{"exact", "中文🙂", "中文🙂", 3, false, false},
		{"byte-boundary", "a🙂🙂"[:8], "a🙂", 2, true, true},
		{"incomplete-suffix", "a🙂🙂"[:8], "a🙂", 3, true, true},
		{"byte-limit-exact", "🙂🙂", "🙂🙂", 2, false, false},
		{"byte-limit-more", "🙂🙂", "🙂🙂", 2, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			binding, record, _ := clipboardToolFixture(t, func(context.Context, int) (clipboardText, error) {
				return clipboardText{data: []byte(tc.text), truncated: tc.clipped}, nil
			})
			raw, err := binding.Execute(context.Background(), plugin.ToolCall{Arguments: json.RawMessage(fmt.Sprintf(`{"maxCharacters":%d}`, tc.max))})
			if err != nil {
				t.Fatal(err)
			}
			var result clipboardResult
			if err := json.Unmarshal(raw, &result); err != nil {
				t.Fatal(err)
			}
			if !result.OK || result.Text != tc.want || result.Empty != (tc.text == "") || result.Truncated != tc.truncated || result.Characters != utf8.RuneCountInString(tc.want) || !utf8.ValidString(result.Text) {
				t.Fatalf("result = %+v", result)
			}
			var row struct {
				Result map[string]any `json:"result"`
			}
			if len(record.Transcript) != 1 {
				t.Fatalf("audit rows = %d", len(record.Transcript))
			}
			if err := json.Unmarshal(record.Transcript[0], &row); err != nil {
				t.Fatal(err)
			}
			if _, exists := row.Result["text"]; exists || row.Result["redacted"] != true || row.Result["characters"] != float64(result.Characters) || row.Result["truncated"] != result.Truncated || row.Result["empty"] != result.Empty {
				t.Fatalf("audit metadata = %v", row.Result)
			}
			if tc.want != "" {
				encoded, _ := json.Marshal(tc.want)
				if strings.Contains(string(record.Transcript[0]), string(encoded)) {
					t.Fatal("clipboard text was persisted in transcript")
				}
			}
		})
	}
}

func TestClipboardFailuresArePrivate(t *testing.T) {
	for _, failure := range []error{errors.New("sensitive-token-123"), errClipboardIndeterminate, errClipboardUnsupported, fmt.Errorf("sensitive-token-123: %w", errClipboardIndeterminate)} {
		binding, record, _ := clipboardToolFixture(t, func(context.Context, int) (clipboardText, error) {
			return clipboardText{}, failure
		})
		_, err := binding.Execute(context.Background(), plugin.ToolCall{Arguments: json.RawMessage(`{}`)})
		if err == nil || strings.Contains(err.Error(), "sensitive-token-123") || strings.Contains(string(record.Transcript[0]), "sensitive-token-123") {
			t.Fatalf("unsafe failure: %v, transcript: %s", err, record.Transcript)
		}
		if failure == errClipboardIndeterminate && !errors.Is(err, errClipboardIndeterminate) {
			t.Fatalf("indeterminate error lost: %v", err)
		}
	}
	_, err := readClipboard(context.Background(), 10, func(context.Context, int) (clipboardText, error) {
		return clipboardText{data: []byte{0xff}}, nil
	})
	if err == nil {
		t.Fatal("invalid UTF-8 accepted")
	}
}

func TestClipboardTranscriptRedactsUnexpectedErrors(t *testing.T) {
	_, record, _ := clipboardToolFixture(t, nil)
	record.Transcript = []json.RawMessage{json.RawMessage(`{"type":"tool-operation","name":"read_clipboard","executionId":"e","callId":"c"}`)}
	c := Coordinator{config: Configuration{UpdateThread: func(_ context.Context, _ string, update func(*model.ThreadRecord) error) error {
		return update(record)
	}}}
	if err := c.completeTool(context.Background(), "moku", "e", "c", json.RawMessage(`{"error":"sensitive-token-123"}`), true); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(record.Transcript[0]), "sensitive-token-123") || !strings.Contains(string(record.Transcript[0]), `"redacted":true`) {
		t.Fatalf("unsafe error audit: %s", record.Transcript[0])
	}
}

func TestClipboardDeadlineAndCancellation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	_, err := readClipboard(ctx, 10, func(ctx context.Context, _ int) (clipboardText, error) {
		<-ctx.Done()
		return clipboardText{}, ctx.Err()
	})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("deadline error = %v", err)
	}
	cancelled, stop := context.WithCancel(context.Background())
	stop()
	binding, _, _ := clipboardToolFixture(t, func(context.Context, int) (clipboardText, error) {
		t.Fatal("cancelled invocation reached reader")
		return clipboardText{}, nil
	})
	if _, err := binding.Execute(cancelled, plugin.ToolCall{Arguments: json.RawMessage(`{}`)}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation error = %v", err)
	}
}

func assertPrivateClipboardFailure(t *testing.T, record *model.ThreadRecord, raw json.RawMessage, err error, sentinel string) map[string]any {
	t.Helper()
	if err == nil {
		t.Fatal("clipboard invocation unexpectedly succeeded")
	}
	transcript, marshalErr := json.Marshal(record.Transcript)
	if marshalErr != nil {
		t.Fatal(marshalErr)
	}
	for name, value := range map[string]string{"return value": string(raw), "error": err.Error(), "transcript": string(transcript)} {
		if strings.Contains(value, sentinel) {
			t.Fatalf("clipboard sentinel leaked into %s", name)
		}
	}
	if len(record.Transcript) != 1 {
		t.Fatalf("audit rows = %d, want 1", len(record.Transcript))
	}
	var row struct {
		Name        string         `json:"name"`
		CompletedAt int64          `json:"completedAt"`
		IsError     bool           `json:"isError"`
		Result      map[string]any `json:"result"`
	}
	if err := json.Unmarshal(record.Transcript[0], &row); err != nil {
		t.Fatal(err)
	}
	if row.Name != "read_clipboard" || row.CompletedAt <= 0 || !row.IsError || row.Result["redacted"] != true {
		t.Fatalf("clipboard audit not settled privately: %s", record.Transcript[0])
	}
	return row.Result
}

func TestClipboardInFlightCancellationIsPrivate(t *testing.T) {
	sentinel := "SENTINEL_CLIPBOARD_" + newID()
	started := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	binding, record, _ := clipboardToolFixture(t, func(ctx context.Context, _ int) (clipboardText, error) {
		close(started)
		<-ctx.Done()
		return clipboardText{data: []byte(sentinel)}, fmt.Errorf("%s: %w", sentinel, ctx.Err())
	})
	done := make(chan struct{})
	var raw json.RawMessage
	var err error
	go func() {
		defer close(done)
		raw, err = binding.Execute(ctx, plugin.ToolCall{Arguments: json.RawMessage(`{}`)})
	}()
	<-started
	cancel()
	<-done
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation error = %v", err)
	}
	if result := assertPrivateClipboardFailure(t, record, raw, err, sentinel); len(result) != 1 {
		t.Fatalf("unexpected error metadata: %v", result)
	}
}

func TestClipboardReaderPanicIsPrivate(t *testing.T) {
	sentinel := "SENTINEL_CLIPBOARD_" + newID()
	binding, record, _ := clipboardToolFixture(t, func(context.Context, int) (clipboardText, error) {
		panic(sentinel)
	})
	raw, err := binding.Execute(context.Background(), plugin.ToolCall{Arguments: json.RawMessage(`{}`)})
	if result := assertPrivateClipboardFailure(t, record, raw, err, sentinel); len(result) != 1 {
		t.Fatalf("unexpected panic metadata: %v", result)
	}
	if err.Error() != "Moku tool handler failed" {
		t.Fatalf("panic error = %v", err)
	}
}

func TestClipboardProductionTimeoutIsPrivate(t *testing.T) {
	sentinel := "SENTINEL_CLIPBOARD_" + newID()
	var deadline, entered time.Time
	binding, record, _ := clipboardToolFixture(t, func(ctx context.Context, _ int) (clipboardText, error) {
		entered = time.Now()
		deadline, _ = ctx.Deadline()
		<-ctx.Done()
		return clipboardText{data: []byte(sentinel)}, fmt.Errorf("%s: %w", sentinel, ctx.Err())
	})
	// A longer parent deadline bounds a regression without supplying the tool's
	// production two-second deadline for it.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	started := time.Now()
	raw, err := binding.Execute(ctx, plugin.ToolCall{Arguments: json.RawMessage(`{}`)})
	finished := time.Now()
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("timeout error = %v", err)
	}
	if deadline.Before(started.Add(2*time.Second)) || deadline.After(entered.Add(2*time.Second)) || deadline.After(finished) || finished.Sub(started) < 2*time.Second {
		t.Fatalf("expected production two-second timeout, deadline offset = %v, elapsed = %v", deadline.Sub(started), finished.Sub(started))
	}
	if result := assertPrivateClipboardFailure(t, record, raw, err, sentinel); len(result) != 1 {
		t.Fatalf("unexpected timeout metadata: %v", result)
	}
}

func TestClipboardLifecycleSettlement(t *testing.T) {
	for _, lifecycle := range []string{"termination", "restart"} {
		for _, name := range []string{"read_clipboard", "list_threads"} {
			t.Run(lifecycle+"/"+name, func(t *testing.T) {
				_, record, c := clipboardToolFixture(t, nil)
				record.Transcript = []json.RawMessage{json.RawMessage(fmt.Sprintf(`{"type":"tool-operation","name":%q,"executionId":"execution","callId":"c"}`, name))}
				want := "Moku execution was interrupted during restart"
				var err error
				if lifecycle == "termination" {
					record.Observation.LatestExecution.Status = "interrupted"
					err = c.settleExecution(context.Background(), *record)
					want = "Moku execution terminated before tool completion"
				} else {
					err = c.settleStaleTranscript(context.Background(), *record)
				}
				if err != nil {
					t.Fatal(err)
				}
				var row struct {
					CompletedAt int64          `json:"completedAt"`
					IsError     bool           `json:"isError"`
					Result      map[string]any `json:"result"`
				}
				if err := json.Unmarshal(record.Transcript[0], &row); err != nil {
					t.Fatal(err)
				}
				if row.CompletedAt <= 0 || !row.IsError || row.Result["error"] != want {
					t.Fatalf("lifecycle error changed: %s", record.Transcript[0])
				}
				if name == "read_clipboard" {
					if row.Result["redacted"] != true || len(row.Result) != 2 {
						t.Fatalf("missing clipboard redaction: %v", row.Result)
					}
				} else if len(row.Result) != 1 {
					t.Fatalf("other tool behavior changed: %v", row.Result)
				}
			})
		}
	}
}

func TestClipboardTerminationCompletionRaceIsPrivate(t *testing.T) {
	for _, order := range []string{"termination-first", "completion-first", "concurrent"} {
		t.Run(order, func(t *testing.T) {
			sentinel := "SENTINEL_CLIPBOARD_" + newID()
			started, release := make(chan struct{}), make(chan struct{})
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			binding, record, c := clipboardToolFixture(t, func(ctx context.Context, _ int) (clipboardText, error) {
				close(started)
				<-ctx.Done()
				<-release
				return clipboardText{data: []byte(sentinel)}, errors.New(sentinel)
			})
			done := make(chan struct{})
			var raw json.RawMessage
			var invokeErr error
			go func() {
				defer close(done)
				raw, invokeErr = binding.Execute(ctx, plugin.ToolCall{Arguments: json.RawMessage(`{}`)})
			}()
			<-started
			terminal := model.ThreadRecord{ID: record.ID, Moku: true}
			terminal.Observation.LatestExecution = &model.PublicExecution{ExecutionID: "execution", Status: "interrupted"}
			settled := make(chan error, 1)
			settle := func() { settled <- c.settleExecution(context.Background(), terminal) }
			cancel()
			switch order {
			case "termination-first":
				settle()
				close(release)
			case "completion-first":
				close(release)
				<-done
				settle()
			case "concurrent":
				go func() { <-release; settle() }()
				close(release)
			}
			<-done
			if err := <-settled; err != nil {
				t.Fatal(err)
			}
			result := assertPrivateClipboardFailure(t, record, raw, invokeErr, sentinel)
			if order == "termination-first" && !strings.Contains(invokeErr.Error(), "already completed") {
				t.Fatalf("late completion was not rejected: %v", invokeErr)
			}
			if order == "completion-first" && !errors.Is(invokeErr, context.Canceled) {
				t.Fatalf("completed invocation changed: %v", invokeErr)
			}
			if message, terminated := result["error"]; terminated {
				if order == "completion-first" || message != "Moku execution terminated before tool completion" || len(result) != 2 {
					t.Fatalf("unexpected termination metadata: %v", result)
				}
			} else if order == "termination-first" || len(result) != 1 {
				t.Fatalf("unexpected completion metadata: %v", result)
			}
		})
	}
}

func TestClipboardCommand(t *testing.T) {
	for _, mode := range []string{"text", "empty", "excess", "failure", "hang", "missing", "bad-flag"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestClipboardHelperProcess$")
			command.Env = append(os.Environ(), "MOKU_CLIPBOARD_TEST_HELPER="+mode)
			value, err := runClipboardCommand(ctx, command, 4)
			switch mode {
			case "text":
				if err != nil || string(value.data) != "test" || !value.truncated {
					t.Fatalf("result = %+v, %v", value, err)
				}
			case "empty":
				if err != nil || len(value.data) != 0 || value.truncated {
					t.Fatalf("empty = %+v, %v", value, err)
				}
			case "hang":
				if !errors.Is(err, context.DeadlineExceeded) {
					t.Fatalf("timeout = %v", err)
				}
			default:
				if !errors.Is(err, errClipboardIndeterminate) || strings.Contains(err.Error(), "sensitive-token") {
					t.Fatalf("error = %v", err)
				}
			}
		})
	}
}

func TestClipboardHelperProcess(t *testing.T) {
	switch os.Getenv("MOKU_CLIPBOARD_TEST_HELPER") {
	case "":
		return
	case "text":
		fmt.Print("1test")
	case "empty":
		fmt.Print("0")
	case "excess":
		fmt.Print("0" + strings.Repeat("x", 100000))
	case "failure":
		fmt.Fprint(os.Stderr, "sensitive-token")
		os.Exit(1)
	case "hang":
		time.Sleep(time.Minute)
	case "missing":
	case "bad-flag":
		fmt.Print("x")
	}
	os.Exit(0)
}

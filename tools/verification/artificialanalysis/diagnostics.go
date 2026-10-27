package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	aa "github.com/hupao-creator/Mokusei/internal/plugins/contexts/artificialanalysis"
)

type diagnosticHTTP struct {
	fixture
	mode     atomic.Int32
	requests atomic.Int32
	started  chan struct{}
}

func (f *diagnosticHTTP) Do(req *http.Request) (*http.Response, error) {
	if req.URL.Path == "/models/" && f.mode.Load() == 1 {
		models := make([]any, 100)
		for i := range models {
			models[i] = model(fmt.Sprintf("model-a-%d", i), "model-a", "Model A")
		}
		return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(`\"initialModels\":` + embedded(models)))}, nil
	}
	if req.URL.Path != "/models/" {
		switch f.mode.Load() {
		case 1:
			if f.requests.Add(1) == 4 {
				close(f.started)
			}
			<-req.Context().Done()
			return nil, req.Context().Err()
		case 2:
			return nil, errors.New("private-upstream-error-canary")
		case 3:
			return &http.Response{StatusCode: 503, Header: http.Header{}, Body: io.NopCloser(strings.NewReader("private-response-canary"))}, nil
		}
	}
	return f.fixture.Do(req)
}

type diagnosticRecord struct {
	event  string
	fields map[string]any
}

func diagnosticsReplay() {
	catalogDeadlineDiagnosticReplay()
	for _, cancelled := range []bool{true, false} {
		root, err := os.MkdirTemp("", "mokusei-aa-diagnostics-")
		require(err == nil, "diagnostics root")
		client := &diagnosticHTTP{started: make(chan struct{})}
		var mu sync.Mutex
		var records []diagnosticRecord
		source, err := aa.NewSource(aa.Options{CacheRoot: root, HTTPClient: client, Log: func(event string, fields map[string]any) {
			summary := aa.DiagnosticSummary(fields).Error()
			require(!strings.Contains(summary, "canary"), "upstream text leaked")
			mu.Lock()
			defer mu.Unlock()
			records = append(records, diagnosticRecord{event, fields})
		}})
		require(err == nil, "diagnostics source")
		ids := []aa.AcquisitionIdentity{{Names: []string{"model-a"}}}
		if cancelled {
			client.mode.Store(1)
			done := make(chan error, 1)
			go func() { done <- source.Refresh(context.Background(), ids) }()
			select {
			case <-client.started:
			case <-time.After(3 * time.Second):
				panic("four detail workers did not start")
			}
			require(source.Close() == nil, "cancelled source drain")
			require(errors.Is(<-done, context.Canceled), "source cancellation result changed")
			require(client.requests.Load() == 4, "cancelled source dispatched remaining details")
			failed, stopped := 0, 0
			for _, r := range records {
				if strings.HasSuffix(r.event, ".failed") {
					failed++
				}
				if r.event == "aa.facts.refresh.cancelled" {
					stopped++
					require(r.fields["class"] == "cancelled" && r.fields["retained"] == false, "cancellation summary")
				}
			}
			require(failed == 0 && stopped == 1, "shutdown emitted per-configuration failures")
		} else {
			_, err = source.WaitForBootstrap(context.Background(), ids)
			require(err == nil, "warm diagnostics cache")
			before := source.Snapshot()
			for _, mode := range []int32{2, 3} {
				client.mode.Store(mode)
				require(source.Refresh(context.Background(), ids) == nil, "detail fallback changed refresh outcome")
			}
			require(source.Close() == nil, "failed source drain")
			classes := map[string]bool{}
			for _, r := range records {
				if r.event == "aa.facts.configuration.failed" {
					classes[r.fields["class"].(string)] = true
					require(r.fields["retained"] == true, "detail failure lost cache retention")
					duration, ok := r.fields["durationMs"].(int64)
					require(ok && duration >= 0, "detail failure lost duration")
				}
			}
			require(classes["unavailable"] && classes["http"], "real failures lost classification")
			require(len(source.Snapshot().Releases) == len(before.Releases) && len(before.Releases) > 0, "detail failure discarded cache")
		}
		require(source.Close() == nil, "idempotent diagnostics closure")
		require(os.RemoveAll(root) == nil, "diagnostics fixture removal")
	}
	safe := aa.DiagnosticSummary(map[string]any{"class": "timeout", "durationMs": int64(7), "retained": true, "error": "private-canary", "slug": "private-canary", "catalogId": "private-canary"}).Error()
	require(strings.Contains(safe, `"class":"timeout"`) && strings.Contains(safe, `"retained":true`) && !strings.Contains(safe, "canary"), "composition diagnostic whitelist")
	require(aa.DiagnosticSummary(map[string]any{"class": "cancelled|timeout", "durationMs": int64(-1)}).Error() == "{}", "invalid diagnostic metadata accepted")
	fmt.Println("PASS AA cancellation stops remaining detail dispatch, emits one cancellation summary, retains cache on real failures, preserves bounded classification/duration/retention without upstream text")
}

func catalogDeadlineDiagnosticReplay() {
	root, err := os.MkdirTemp("", "mokusei-aa-deadline-")
	require(err == nil, "catalog deadline root")
	defer os.RemoveAll(root)
	var record diagnosticRecord
	source, err := aa.NewSource(aa.Options{CacheRoot: root, Log: func(event string, fields map[string]any) {
		record = diagnosticRecord{event, fields}
	}})
	require(err == nil, "catalog deadline source")
	defer source.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	_, err = aa.Collect(ctx, source, plugin.MokuContextInput{Catalogs: []plugin.BoundModelCatalog{{ID: "codex", Load: func(ctx context.Context) (json.RawMessage, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}}}})
	require(errors.Is(err, context.DeadlineExceeded), "catalog deadline result changed")
	require(record.event == "aa.context.catalog.failed" && record.fields["class"] == "timeout", "catalog deadline misclassified as normal cancellation")
}

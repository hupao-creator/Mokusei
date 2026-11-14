package transport

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

type contentBenchmarkHost struct {
	Host
	value    json.RawMessage
	revision int64
}

func (h *contentBenchmarkHost) ReadThreadContent(context.Context, string, ContentScope, *int64) (*ContentSnapshot, error) {
	h.revision++
	return &ContentSnapshot{Revision: h.revision, Value: h.value}, nil
}

// Exercises the actual publish path; excludes Harness projection, HTTP and UI.
// A revision bump represents hidden detail churn or an unrelated turn update.
func BenchmarkUnchangedContent(b *testing.B) {
	for _, size := range []int{2048, 256 * 1024} {
		for _, reencoded := range []bool{false, true} {
			b.Run(fmt.Sprintf("bytes=%d/reencoded=%t", size, reencoded), func(b *testing.B) {
				raw, err := json.Marshal(map[string]any{"message": strings.Repeat("x", size), "tools": 12})
				if err != nil {
					b.Fatal(err)
				}
				alternate := append([]byte(" \n"), raw...)
				host := &contentBenchmarkHost{value: raw}
				stream := newEventStream("benchmark")
				sub := &contentSubscription{ctx: context.Background(), id: "row", target: contentTarget{ThreadID: "thread", Scope: ContentScope{Kind: "turn", Key: "turn"}}}
				server := &contentServer{host: host, clients: map[string]map[string]*contentSubscription{"client": {"row": sub}}, client: func(string) *eventStream { return stream }}
				server.publishOne("client", sub)
				initial, _ := stream.pop()
				if len(initial) == 0 || !sub.hasValue {
					b.Fatal("missing initial snapshot")
				}
				b.ReportAllocs()
				b.SetBytes(int64(len(raw)))
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					host.value = raw
					if reencoded && i%2 == 0 {
						host.value = alternate
					}
					server.publishOne("client", sub)
				}
				b.StopTimer()
				if sub.sourceRevision == nil || *sub.sourceRevision != host.revision || sub.revision != 1 {
					b.Fatal("no-op broke source/wire revisions")
				}
				if unexpected, _ := stream.pop(); len(unexpected) != 0 {
					b.Fatal("unchanged content emitted an event")
				}
				// Keep this a small text edit so the first visible change still
				// exercises the incremental patch path after semantic no-ops.
				changed := append([]byte(nil), raw...)
				changed[strings.Index(string(raw), strings.Repeat("x", 8))] = 'y'
				host.value = changed
				server.publishOne("client", sub)
				body, _ := stream.pop()
				var outer struct {
					Event struct {
						Type                   string
						BaseRevision, Revision int64
					}
				}
				if err := json.Unmarshal(body, &outer); err != nil {
					b.Fatal(err)
				}
				if outer.Event.Type != "patch" || outer.Event.BaseRevision != 1 || outer.Event.Revision != 2 {
					b.Fatal("first visible change after no-ops broke patch chain")
				}
			})
		}
	}
}

func BenchmarkChangedContent(b *testing.B) {
	for _, size := range []int{2048, 256 * 1024} {
		b.Run(fmt.Sprintf("bytes=%d", size), func(b *testing.B) {
			raw, err := json.Marshal(map[string]any{"message": strings.Repeat("x", size), "tools": 12})
			if err != nil {
				b.Fatal(err)
			}
			alternate := append([]byte(nil), raw...)
			alternate[strings.Index(string(raw), strings.Repeat("x", 8))] = 'y'
			host := &contentBenchmarkHost{value: raw}
			stream := newEventStream("benchmark")
			sub := &contentSubscription{ctx: context.Background(), id: "row", target: contentTarget{ThreadID: "thread", Scope: ContentScope{Kind: "turn", Key: "turn"}}}
			server := &contentServer{host: host, clients: map[string]map[string]*contentSubscription{"client": {"row": sub}}, client: func(string) *eventStream { return stream }}
			server.publishOne("client", sub)
			stream.pop()
			b.ReportAllocs()
			b.SetBytes(int64(len(raw)))
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				host.value = alternate
				if i%2 == 1 {
					host.value = raw
				}
				server.publishOne("client", sub)
				event, _ := stream.pop()
				if len(event) == 0 {
					b.Fatal("changed content did not publish")
				}
			}
			b.StopTimer()
			if sub.sourceRevision == nil || *sub.sourceRevision != host.revision || sub.revision != int64(b.N+1) {
				b.Fatal("change broke revision chain")
			}
		})
	}
}

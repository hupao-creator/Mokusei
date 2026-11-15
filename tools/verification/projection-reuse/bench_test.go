package main

import (
	"context"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/sessioncache"
)

func BenchmarkReaderNarrowScopes(b *testing.B) {
	ctx := context.Background()
	for _, f := range fixtures() {
		for _, body := range []int{256 << 10, 8 << 20} {
			state := f.state(8, body, "target-answer")
			contentID := sessioncache.Identity(state)
			scope := model.RendererScope{Kind: "execution", Key: f.target}
			b.Run(f.name+"/cold/"+sizeName(body), func(b *testing.B) {
				b.ReportAllocs()
				b.SetBytes(int64(len(state)))
				for i := 0; i < b.N; i++ {
					adapter := f.newAdapter()
					reader := adapter.(plugin.ReaderProjectionAdapter)
					snapshot, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "bench", ContentID: contentID, State: state, Scope: scope, Generation: 1})
					if err != nil || snapshot == nil {
						b.Fatalf("cold projection: %v", err)
					}
				}
			})
			b.Run(f.name+"/same/"+sizeName(body), func(b *testing.B) {
				adapter := f.newAdapter()
				reader := adapter.(plugin.ReaderProjectionAdapter)
				first, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "bench", ContentID: contentID, State: state, Scope: scope, Generation: 1})
				if err != nil {
					b.Fatal(err)
				}
				known := first.Revision
				b.ReportAllocs()
				b.SetBytes(int64(len(state)))
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					snapshot, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "bench", ContentID: contentID, State: state, Scope: scope, Known: &known, Generation: 2})
					if err != nil || snapshot != nil {
						b.Fatalf("same-version projection: %v", err)
					}
				}
			})
			alternates := [][]byte{f.state(8, body*2, "target-answer"), f.state(8, body*3, "target-answer")}
			ids := []string{sessioncache.Identity(alternates[0]), sessioncache.Identity(alternates[1])}
			b.Run(f.name+"/unrelated/"+sizeName(body), func(b *testing.B) {
				adapter := f.newAdapter()
				reader := adapter.(plugin.ReaderProjectionAdapter)
				first, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "bench", ContentID: contentID, State: state, Scope: scope, Generation: 1})
				if err != nil {
					b.Fatal(err)
				}
				known := first.Revision
				b.ReportAllocs()
				b.SetBytes(int64(len(state)))
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					index := i % len(alternates)
					snapshot, err := reader.ProjectReader(ctx, plugin.ReaderRequest{ThreadID: "bench", ContentID: ids[index], State: alternates[index], Scope: scope, Known: &known, Generation: int64(2 + i)})
					if err != nil || snapshot != nil {
						b.Fatalf("unrelated projection: %v", err)
					}
				}
			})
		}
	}
}

func sizeName(body int) string {
	if body >= 1<<20 {
		return "8MiB"
	}
	return "256KiB"
}

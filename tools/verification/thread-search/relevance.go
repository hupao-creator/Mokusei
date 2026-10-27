package main

import (
	"context"
	"fmt"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/localembedding"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

// Replay realistic score ranges through runtime, durable chunks and managed
// HTTP inference. Synthetic vectors test filtering, not model quality.
func verifyRelevance(ctx context.Context, directory string, provider *localembedding.Provider) {
	defer provider.Close()
	install(provider)
	db, err := store.Open(filepath.Join(directory, "relevance.sqlite"))
	must(err)
	defer db.Close()
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": harness{}}, DataDir: directory, DefaultCwd: directory, Embeddings: provider})
	must(err)
	defer func() { must(r.Close(ctx)) }()
	seed(db,
		thread("old-floor", "Unrelated A", "relevance-fixture-score:0.60"),
		thread("weak", "Unrelated B", "relevance-fixture-score:0.699"),
		thread("related", "Related", "relevance-fixture-score:0.701"),
		thread("strong", "Strong", "relevance-fixture-score:0.77"),
		thread("literal", "相关性校准 exact-ID-42", "relevance-fixture-score:0.61"),
		thread("body", "Body match", "relevance-fixture-score:0.62 相关性校准"),
	)
	configure(r, true, false)
	start(r)
	result := query(r, "相关性校准", refs("old-floor", "weak", "related", "strong", "literal", "body")...)
	assert(result.Mode == "hybrid" && len(result.Hits) == 4, "weak semantic scores excluded while title/body literals survive")
	for i, id := range []string{"literal", "body", "strong", "related"} {
		assert(result.Hits[i].Ref.ThreadID == id, "literal priority and descending semantic relevance")
	}
	assert(len(query(r, "相关性校准", refs("old-floor", "weak")...).Hits) == 0, "an unrelated scope stays empty instead of filling top results")
	assert(len(query(r, "相关性校准", refs("related")...).Hits) == 1, "semantic-only paraphrase above the floor survives")
	result = invoke(r, "search:query", threadsearch.QueryRequest{Query: "相关性校准", Threads: refs("weak"), KeywordMatches: refs("weak")}).(threadsearch.QueryResult)
	assert(len(result.Hits) == 1 && result.Hits[0].Ref.ThreadID == "weak", "native folded metadata matches survive a low semantic score")
	fmt.Println("PASS semantic relevance floor, empty unrelated scope, paraphrase recall and literal priority through production runtime")
}

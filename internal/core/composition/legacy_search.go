package composition

import (
	"os"
	"path/filepath"
)

// removeLegacyEmbeddingArtifacts discards derived assets from the removed local
// embedding search. They contain no authored state; keeping them would leave a
// stale vector index and model cache with no reader. A terminal symlink is
// unlinked without following it. Removal is best-effort: startup must not fail
// because an old derived cache is locked or otherwise inaccessible.
func removeLegacyEmbeddingArtifacts(stateRoot string, log func(string, error)) {
	for _, name := range []string{"search-index.sqlite", "search-index.sqlite-wal", "search-index.sqlite-shm", "search-index.sqlite-journal", "search-models"} {
		if err := os.RemoveAll(filepath.Join(stateRoot, name)); err != nil && log != nil {
			log("search.legacy-embedding", err)
		}
	}
}

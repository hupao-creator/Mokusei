// Package threadsearch owns derived keyword thread retrieval data. It never
// opens native sessions or discovers credentials. Source adapters retain their
// ownership of thread history and determine which documents are user-visible.
package threadsearch

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

const indexVersion = "keyword-text-v1"
const documentPrefix = "search-document:"
const configKey = "search-config"
const maxContentRunes = 134550

type Source struct {
	Busy       bool
	Ref        model.ThreadRef
	Owner      string
	OwnerHash  string
	Identity   string
	Title, Cwd string
	Tags       []string
	Content    string
	// LoadContent captures one immutable source and runs only after eligibility checks.
	LoadContent func() (string, error)
}

func RefKey(ref model.ThreadRef) string { raw, _ := json.Marshal(ref); return Hash(raw) }
func Hash(raw []byte) string            { h := sha256.Sum256(raw); return hex.EncodeToString(h[:]) }
func (s Source) fingerprint() string {
	raw, _ := json.Marshal([]any{indexVersion, s.Title, s.Cwd, s.Tags, s.Content})
	return Hash(raw)
}
func (s Source) metadata() string { return s.Title + "\n" + s.Cwd + "\n" + strings.Join(s.Tags, " ") }

type Document struct {
	Ref         model.ThreadRef `json:"ref"`
	Owner       string          `json:"owner"`
	SourceHash  string          `json:"sourceHash"`
	Fingerprint string          `json:"fingerprint"`
	Version     string          `json:"version"`
	LiteralText string          `json:"literalText"`
	Truncated   bool            `json:"truncated"`
}

func prepare(source Source) Document {
	metadata := []rune(source.metadata())
	if len(metadata) > 512 {
		metadata = metadata[:512]
	}
	text := []rune(source.Content)
	// Preserve the historical bounded continuous body coverage.
	return Document{Ref: source.Ref, Owner: source.Owner, Fingerprint: source.fingerprint(), SourceHash: source.OwnerHash,
		Version: indexVersion, Truncated: len(text) > maxContentRunes,
		LiteralText: string(metadata) + "\n" + string(text[:min(len(text), maxContentRunes)])}
}

// DeleteOwner is called inside the same transaction that deletes its source.
// Removing derived text atomically prevents reuse of a deleted owner.
func DeleteOwner(tx *store.Tx, owner string) error {
	for _, key := range tx.Keys(documentPrefix) {
		var document Document
		if _, err := tx.Get(key, &document); err != nil {
			return err
		}
		if document.Owner == owner {
			if err := tx.Delete(key); err != nil {
				return err
			}
		}
	}
	return nil
}

// ClearHistory participates in runtime's fenced replacement transaction.
// Derived content is removed atomically; automatic search remains ready for new threads.
func ClearHistory(tx *store.Tx) error {
	for _, key := range tx.Keys(documentPrefix) {
		if err := tx.Delete(key); err != nil {
			return err
		}
	}
	config, err := readConfig(tx.Snapshot())
	if err != nil {
		return err
	}
	config.Revision++
	config.Epoch++
	return tx.Put(configKey, config)
}

// Revision is safe catalog metadata used to invalidate clients across windows.
func Revision(snapshot store.Snapshot) int64 {
	config, err := readConfig(snapshot)
	if err != nil {
		return 0
	}
	return int64(config.Revision)
}

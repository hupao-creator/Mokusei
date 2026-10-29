// Package threadsearch owns consented, derived thread retrieval data. It never
// opens native sessions or discovers credentials. Source adapters retain their
// ownership of thread history and determine which documents are user-visible.
package threadsearch

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

const Dimensions = 768
const indexVersion = plugin.LocalEmbeddingSpace + "/text-v4-completed/runes1200-overlap150/v2"
const documentPrefix = "search-document:"
const configKey = "search-config"
const maxChunks = 128

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

type Chunk struct {
	Title  string    `json:"title"`
	Text   string    `json:"text"`
	Hash   string    `json:"hash"`
	Vector []float32 `json:"vector,omitempty"`
}
type Document struct {
	Ref         model.ThreadRef `json:"ref"`
	Owner       string          `json:"owner"`
	SourceHash  string          `json:"sourceHash"`
	Fingerprint string          `json:"fingerprint"`
	Version     string          `json:"version"`
	LiteralText string          `json:"literalText"`
	Chunks      []Chunk         `json:"chunks"`
	Truncated   bool            `json:"truncated"`
}

func prepare(source Source, previous Document) Document {
	metadata := []rune(source.metadata())
	if len(metadata) > 512 {
		metadata = metadata[:512]
	}
	text := []rune(source.Content)
	chunks := []string{string(metadata)}
	truncated := false
	if len(text) != 0 {
		chunks = nil
		for start := 0; start < len(text); start += 1050 {
			end := min(start+1200, len(text))
			chunks = append(chunks, string(metadata)+"\n"+string(text[start:end]))
			if end == len(text) {
				break
			}
			if len(chunks) == maxChunks {
				truncated = true
				break
			}
		}
	}
	// Keep exactly the contiguous content covered by the bounded vector index.
	literalText := string(metadata) + "\n" + string(text[:min(len(text), (maxChunks-1)*1050+1200)])
	cached := map[string][]float32{}
	if previous.Version == indexVersion {
		for _, chunk := range previous.Chunks {
			if validVector(chunk.Vector) {
				cached[chunk.Hash] = chunk.Vector
			}
		}
	}
	document := Document{Ref: source.Ref, Owner: source.Owner, Fingerprint: source.fingerprint(), SourceHash: source.OwnerHash, Version: indexVersion, Truncated: truncated, LiteralText: literalText}
	for _, text := range chunks {
		// Metadata is already in the content, so use a bounded, stable title.
		title := []rune(source.Title)
		if len(title) > 128 {
			title = title[:128]
		}
		if len(title) == 0 {
			title = []rune("none")
		}
		encoded := "title: " + string(title) + " | text: " + text
		hash := Hash([]byte(encoded))
		document.Chunks = append(document.Chunks, Chunk{Title: string(title), Text: text, Hash: hash, Vector: cached[hash]})
	}
	return document
}

// DeleteOwner is called inside the same transaction that deletes its source.
// It also forgets its explicit authorization, preventing an ID reuse from
// resurrecting a deleted document when an old HTTP response arrives.
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
	var config Config
	ok, err := tx.Get(configKey, &config)
	if err != nil || !ok {
		return err
	}
	changed := false
	for key, identity := range config.Scope {
		if strings.HasPrefix(identity, owner+"\x00") {
			delete(config.Scope, key)
			changed = true
		}
	}
	if changed {
		return tx.Put(configKey, config)
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
	config.Enabled = true
	config.IncludeContent = true
	config.AutoUpdate = true
	config.AutomaticVersion = automaticVersion
	config.IndexPaused = false
	config.Scope = map[string]string{}
	config.Revision++
	config.Epoch++
	return tx.Put(configKey, config)
}

// Maintenance-only removal can still suspend preparation until the next explicit
// start. This is not a product settings toggle or a history-clear policy.
func disableIndex(tx *store.Tx) error {
	if err := ClearHistory(tx); err != nil {
		return err
	}
	c, err := readConfig(tx.Snapshot())
	if err != nil {
		return err
	}
	c.Enabled = false
	return tx.Put(configKey, c)
}

// Revision is safe catalog metadata used to invalidate clients across windows.
func Revision(snapshot store.Snapshot) int64 {
	config, err := readConfig(snapshot)
	if err != nil {
		return 0
	}
	return int64(config.Revision)
}

func (c Chunk) prompt() string { return "title: " + c.Title + " | text: " + c.Text }

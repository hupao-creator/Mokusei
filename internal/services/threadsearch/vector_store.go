package threadsearch

import (
	"context"
	"encoding/binary"
	"errors"
	"math"
	"os"
	"path/filepath"
	"sync"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/platform/sqlite"
)

const vectorPipeline = "utf8-passages-overlap192-v2"
const vectorStampPrefix = "search-vector-stamp:"

type vectorStamp struct {
	Generation       string `json:"generation"`
	Space            string `json:"space"`
	Pipeline         string `json:"pipeline"`
	DocumentHash     string `json:"documentHash"`
	Epoch            uint64 `json:"epoch"`
	Passages         int    `json:"passages"`
	MetadataPassages int    `json:"metadataPassages"`
}

// Unlike the authoritative JSON store, this database never loads all vectors
// into a resident snapshot. Its connection is owned by this narrow lock.
type vectorStore struct {
	mu sync.Mutex
	db *sqlite.DB
}

func openVectorStore(path string) (*vectorStore, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	db, err := sqlite.Open(path, false)
	if err != nil {
		return nil, err
	}
	if err = os.Chmod(path, 0600); err == nil {
		err = db.Exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
CREATE TABLE IF NOT EXISTS vectors (space TEXT NOT NULL, hash TEXT NOT NULL, vector BLOB NOT NULL, PRIMARY KEY(space,hash));
CREATE TABLE IF NOT EXISTS generations (id TEXT PRIMARY KEY, space TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS passages (generation TEXT NOT NULL, ordinal INTEGER NOT NULL, hash TEXT NOT NULL, PRIMARY KEY(generation,ordinal));
CREATE INDEX IF NOT EXISTS passages_hash ON passages(hash,generation);`)
	}
	if err != nil {
		db.Close()
		return nil, err
	}
	return &vectorStore{db: db}, nil
}
func (v *vectorStore) close() error { v.mu.Lock(); defer v.mu.Unlock(); return v.db.Close() }
func vectorBytes(vector []float32) []byte {
	raw := make([]byte, len(vector)*4)
	for i, value := range vector {
		binary.LittleEndian.PutUint32(raw[i*4:], math.Float32bits(value))
	}
	return raw
}

// Read one persisted blob in place; scans do not allocate a second float slice
// for every passage. A nil query performs the same boundary validation for reuse.
func vectorDot(raw []byte, dimensions int, query []float32) (float64, error) {
	if len(raw) != dimensions*4 {
		return 0, errors.New("stored vector dimension mismatch")
	}
	var norm, score float64
	for i := 0; i < dimensions; i++ {
		value := float64(math.Float32frombits(binary.LittleEndian.Uint32(raw[i*4:])))
		if math.IsNaN(value) || math.IsInf(value, 0) {
			return 0, errors.New("non-finite stored vector")
		}
		norm += value * value
		if query != nil {
			score += value * float64(query[i])
		}
	}
	if math.Abs(norm-1) > .01 {
		return 0, errors.New("invalid stored vector norm")
	}
	return score, nil
}
func (v *vectorStore) get(space, hash string, dimensions int) (bool, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	rows, err := v.db.Query("SELECT vector FROM vectors WHERE space=? AND hash=?", space, hash)
	if err != nil || len(rows) == 0 {
		return false, err
	}
	raw, ok := rows[0]["vector"].([]byte)
	if !ok {
		return false, errors.New("invalid stored vector encoding")
	}
	_, err = vectorDot(raw, dimensions, nil)
	return err == nil, err
}
func (v *vectorStore) put(space, hash string, vector []float32) error {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.db.Exec("INSERT OR REPLACE INTO vectors(space,hash,vector) VALUES(?,?,?)", space, hash, vectorBytes(vector))
}
func (v *vectorStore) has(id string) bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	rows, err := v.db.Query("SELECT id FROM generations WHERE id=?", id)
	return err == nil && len(rows) == 1
}
func (v *vectorStore) publish(id, space string, hashes []string) (err error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if err = v.db.Exec("BEGIN IMMEDIATE"); err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = v.db.Exec("ROLLBACK")
		}
	}()
	if err = v.db.Exec("INSERT OR REPLACE INTO generations(id,space) VALUES(?,?)", id, space); err != nil {
		return err
	}
	if err = v.db.Exec("DELETE FROM passages WHERE generation=?", id); err != nil {
		return err
	}
	for index, hash := range hashes {
		if err = v.db.Exec("INSERT INTO passages(generation,ordinal,hash) VALUES(?,?,?)", id, index, hash); err != nil {
			return err
		}
	}
	return v.db.Exec("COMMIT")
}

type vectorCandidate struct {
	Key              string
	MetadataPassages int
}

func (v *vectorStore) scores(ctx context.Context, space string, query []float32, allowed map[string]vectorCandidate, metadataWeight float64) (map[string]float64, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	statement, err := v.db.Prepare(`SELECT p.generation,p.ordinal,v.vector FROM passages p
 JOIN generations g ON g.id=p.generation JOIN vectors v ON v.space=g.space AND v.hash=p.hash WHERE g.space=?`)
	if err != nil {
		return nil, err
	}
	defer statement.Close()
	if err = statement.Bind(1, space); err != nil {
		return nil, err
	}
	type parts struct {
		metadata, body       float64
		hasMetadata, hasBody bool
	}
	accumulated := map[string]parts{}
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		row, err := statement.Step()
		if err != nil {
			return nil, err
		}
		if !row {
			break
		}
		candidate, ok := allowed[statement.Text(0)]
		if !ok {
			continue
		}
		score, err := vectorDot(statement.Blob(2), len(query), query)
		if err != nil {
			return nil, err
		}
		value := accumulated[candidate.Key]
		if statement.Integer(1) < int64(candidate.MetadataPassages) {
			if !value.hasMetadata || score > value.metadata {
				value.metadata = score
			}
			value.hasMetadata = true
		} else {
			if !value.hasBody || score > value.body {
				value.body = score
			}
			value.hasBody = true
		}
		accumulated[candidate.Key] = value
	}
	result := map[string]float64{}
	for key, value := range accumulated {
		score := value.body
		if !value.hasBody {
			score = value.metadata
		} else if value.hasMetadata {
			// A long conversation can quote a different task. A small metadata term
			// keeps its strongest passage anchored to this thread's own subject.
			score = (1-metadataWeight)*max(value.body, value.metadata) + metadataWeight*value.metadata
		}
		result[key] = score
	}
	return result, nil
}
func (v *vectorStore) prune(live map[string]bool) (err error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	rows, err := v.db.Query("SELECT id FROM generations")
	if err != nil {
		return err
	}
	if err = v.db.Exec("BEGIN IMMEDIATE"); err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = v.db.Exec("ROLLBACK")
		}
	}()
	for _, row := range rows {
		id, _ := row["id"].(string)
		if live[id] {
			continue
		}
		if err = v.db.Exec("DELETE FROM passages WHERE generation=?", id); err != nil {
			return err
		}
		if err = v.db.Exec("DELETE FROM generations WHERE id=?", id); err != nil {
			return err
		}
	}
	if err = v.db.Exec(`DELETE FROM vectors WHERE NOT EXISTS
(SELECT 1 FROM passages p JOIN generations g ON g.id=p.generation WHERE g.space=vectors.space AND p.hash=vectors.hash)`); err != nil {
		return err
	}
	return v.db.Exec("COMMIT")
}

type embeddingPassage struct {
	Text     string
	Metadata bool
}

func embeddingPassages(document Document, budget int) []embeddingPassage {
	var passages []embeddingPassage
	// Metadata is independent of body offsets: changing a title must not shift
	// every old passage and force inference over otherwise unchanged history.
	for section, text := range []string{document.LiteralText[:document.BodyOffset], document.LiteralText[document.BodyOffset:]} {
		for start := 0; start < len(text); {
			end := min(len(text), start+budget)
			for end < len(text) && !utf8.RuneStart(text[end]) {
				end--
			}
			passages = append(passages, embeddingPassage{text[start:end], section == 0})
			if end == len(text) {
				break
			}
			start = end - min(192, budget/4)
			for !utf8.RuneStart(text[start]) {
				start++
			}
		}
	}
	return passages
}

package threadvoice

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode/utf16"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// Transcript history has no access to task execution or its source records.
type history struct {
	mu             sync.Mutex
	writeMu        sync.Mutex
	path           string
	order          []string
	messages       map[string]plugin.VoiceTranscriptMessage
	version, saved uint64
}

func loadHistory(root, threadID string) (*history, error) {
	digest := sha256.Sum256([]byte(threadID))
	h := &history{path: filepath.Join(root, hex.EncodeToString(digest[:])+".json"), order: []string{}, messages: map[string]plugin.VoiceTranscriptMessage{}}
	body, err := os.ReadFile(h.path)
	if errors.Is(err, os.ErrNotExist) {
		return h, nil
	}
	if err != nil {
		return nil, err
	}
	var messages []plugin.VoiceTranscriptMessage
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err = dec.Decode(&messages); err != nil {
		return nil, err
	}
	if dec.Decode(&struct{}{}) != io.EOF || messages == nil {
		return nil, errors.New("invalid voice transcript history")
	}
	var raw []map[string]json.RawMessage
	if err = json.Unmarshal(body, &raw); err != nil {
		return nil, err
	}
	for i, msg := range messages {
		if len(raw[i]) != 6 {
			return nil, errors.New("voice transcript message has missing fields")
		}
		for _, value := range raw[i] {
			if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
				return nil, errors.New("voice transcript field cannot be null")
			}
		}
		if err = validMessage(msg); err != nil {
			return nil, err
		}
		if _, exists := h.messages[msg.ID]; !exists {
			h.order = append(h.order, msg.ID)
		}
		h.messages[msg.ID] = msg
	}
	return h, nil
}
func validMessage(msg plugin.VoiceTranscriptMessage) error {
	if msg.ID == "" || msg.SessionID == "" || (msg.Role != "user" && msg.Role != "assistant") || msg.CreatedAt < 0 || len(utf16.Encode([]rune(msg.Text))) > 64000 {
		return errors.New("invalid voice transcript message")
	}
	return nil
}
func (h *history) snapshot() []plugin.VoiceTranscriptMessage {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.snapshotLocked(false)
}
func (h *history) snapshotLocked(nonblank bool) []plugin.VoiceTranscriptMessage {
	out := make([]plugin.VoiceTranscriptMessage, 0, len(h.order))
	for _, id := range h.order {
		msg, ok := h.messages[id]
		if ok && (!nonblank || strings.TrimSpace(msg.Text) != "") {
			out = append(out, msg)
		}
	}
	return out
}
func (h *history) update(msg plugin.VoiceTranscriptMessage) error {
	if err := validMessage(msg); err != nil {
		return err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.messages[msg.ID]; !ok {
		h.order = append(h.order, msg.ID)
	}
	h.messages[msg.ID] = msg
	h.version++
	return nil
}
func (h *history) finish(sessionID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	next := h.order[:0]
	for _, id := range h.order {
		msg := h.messages[id]
		if msg.SessionID == sessionID && strings.TrimSpace(msg.Text) == "" {
			delete(h.messages, id)
			h.version++
		} else {
			next = append(next, id)
		}
	}
	h.order = next
}
func (h *history) save(ctx context.Context) error {
	h.writeMu.Lock()
	defer h.writeMu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	h.mu.Lock()
	if h.saved == h.version {
		h.mu.Unlock()
		return nil
	}
	version := h.version
	messages := h.snapshotLocked(true)
	h.mu.Unlock()
	body, err := json.Marshal(messages)
	if err != nil {
		return err
	}
	root := filepath.Dir(h.path)
	if err = os.MkdirAll(root, 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(root, ".voice-history-")
	if err != nil {
		return err
	}
	temp := f.Name()
	defer os.Remove(temp)
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(body)
	}
	if err == nil {
		err = f.Sync()
	}
	err = errors.Join(err, f.Close())
	if err != nil {
		return err
	}
	if err = os.Rename(temp, h.path); err != nil {
		return err
	}
	dir, err := os.Open(root)
	if err != nil {
		return err
	}
	err = errors.Join(dir.Sync(), dir.Close())
	if err != nil {
		return err
	}
	h.mu.Lock()
	h.saved = version
	h.mu.Unlock()
	return nil
}
func (h *history) remove() error {
	h.writeMu.Lock()
	defer h.writeMu.Unlock()
	err := os.Remove(h.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

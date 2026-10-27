// Package git observes local Git worktrees without a model or repository writes.
package git

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	appvalue "github.com/hupao-creator/Mokusei/internal/plugins/applications/value"
)

const Worktrees = "git.worktrees"
const maxPatch = 2 * 1024 * 1024
const maxStatus = 8 * 1024 * 1024

type Snapshot struct {
	Root           string  `json:"root"`
	Branch         *string `json:"branch"`
	Head           *string `json:"head"`
	Upstream       *string `json:"upstream"`
	Ahead          *int    `json:"ahead"`
	Behind         *int    `json:"behind"`
	Changed        int     `json:"changed"`
	Additions      *int    `json:"additions"`
	Deletions      *int    `json:"deletions"`
	LineStatsError *string `json:"lineStatsError"`
	Staged         int     `json:"staged"`
	Unstaged       int     `json:"unstaged"`
	Untracked      int     `json:"untracked"`
	Conflicts      int     `json:"conflicts"`
}
type SyncStatus struct {
	AttemptedAt int64   `json:"attemptedAt"`
	ObservedAt  int64   `json:"observedAt"`
	Error       *string `json:"error"`
}
type View struct {
	Snapshot  Snapshot   `json:"snapshot"`
	Sync      SyncStatus `json:"sync"`
	Available bool       `json:"available"`
}
type Worktree struct {
	View
	Directories []string `json:"directories"`
}
type Activity struct {
	ID string `json:"id"`
	Worktree
}
type Observation struct {
	Root        string    `json:"root"`
	Directories []string  `json:"directories"`
	AttemptedAt int64     `json:"attemptedAt"`
	Snapshot    *Snapshot `json:"snapshot"`
	Error       *string   `json:"error"`
}
type SyncInput struct {
	AttemptedAt  int64         `json:"attemptedAt"`
	Observations []Observation `json:"observations"`
}
type PageInput struct {
	Cursor string `json:"cursor,omitempty"`
	Limit  int    `json:"limit"`
}
type Page[T any] struct {
	Items      []T    `json:"items"`
	NextCursor string `json:"nextCursor,omitempty"`
}
type Selection struct {
	ActivityID string `json:"activityId"`
	Path       string `json:"path"`
	Scope      string `json:"scope"`
}
type FilesInput struct {
	ActivityID string `json:"activityId"`
}
type ChangedFile struct {
	Path      string  `json:"path"`
	OldPath   *string `json:"oldPath"`
	Status    string  `json:"status"`
	Scope     string  `json:"scope"`
	Submodule bool    `json:"submodule"`
}
type FilesResult struct {
	Files  []ChangedFile `json:"files"`
	ReadAt int64         `json:"readAt"`
}
type DiffContent struct {
	Patch  string  `json:"patch"`
	Notice *string `json:"notice"`
}

func ptr[T any](v T) *T { return &v }
func validPath(s string) bool {
	return s != "" && len(s) <= 32768 && utf8.ValidString(s) && !strings.ContainsRune(s, 0)
}
func validRoot(s string) bool { return validPath(s) && filepath.IsAbs(s) && filepath.Clean(s) == s }
func validID(s string) bool   { return s != "" && len(s) <= 256 && !strings.ContainsRune(s, 0) }
func validScope(s string) bool {
	return s == "staged" || s == "unstaged" || s == "untracked" || s == "conflicts"
}
func validError(s *string) bool {
	return s == nil || *s == "unavailable" || *s == "timeout" || *s == "too-large" || *s == "inaccessible"
}
func validateSnapshot(s Snapshot) error {
	if !validRoot(s.Root) || s.Changed < 0 || s.Staged < 0 || s.Unstaged < 0 || s.Untracked < 0 || s.Conflicts < 0 {
		return errors.New("invalid Git snapshot")
	}
	if !validError(s.LineStatsError) || (s.Additions == nil) != (s.Deletions == nil) || s.LineStatsError != nil && s.Additions != nil {
		return errors.New("invalid Git line statistics")
	}
	for _, v := range []*string{s.Branch, s.Head, s.Upstream} {
		if v != nil && (!utf8.ValidString(*v) || len(*v) > 4096) {
			return errors.New("invalid Git ref")
		}
	}
	for _, v := range []*int{s.Ahead, s.Behind, s.Additions, s.Deletions} {
		if v != nil && *v < 0 {
			return errors.New("invalid Git divergence")
		}
	}
	return nil
}
func validateDirectories(directories []string) error {
	if directories == nil || len(directories) > 10000 {
		return errors.New("invalid Git source directories")
	}
	for _, cwd := range directories {
		if !validRoot(cwd) {
			return errors.New("invalid Git source directory")
		}
	}
	return nil
}
func validateWorktree(w *Worktree) error {
	if err := validateSnapshot(w.Snapshot); err != nil {
		return err
	}
	if !validError(w.Sync.Error) || w.Sync.AttemptedAt < 0 || w.Sync.ObservedAt < 0 {
		return errors.New("invalid Git sync")
	}
	return validateDirectories(w.Directories)
}
func contract[T any](id string, validate func(*T) error) plugin.ValueContract {
	return plugin.ValueContract{ID: id, SchemaVersion: 1, Parse: func(raw json.RawMessage) (json.RawMessage, error) {
		var value T
		if err := appvalue.Decode(raw, &value); err != nil {
			return nil, err
		}
		if validate != nil {
			if err := validate(&value); err != nil {
				return nil, err
			}
		}
		return json.Marshal(value)
	}}
}
func operation(id string, input, output plugin.ValueContract) plugin.Operation {
	return plugin.Operation{ID: id, OwnerPluginID: "git", Input: input, Output: output}
}

// decode reads normalized operation inputs or records written by this module.
func decode[T any](raw json.RawMessage) T { var value T; _ = json.Unmarshal(raw, &value); return value }

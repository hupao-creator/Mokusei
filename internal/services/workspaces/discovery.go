package workspaces

import (
	"path/filepath"
	"regexp"
	"strings"
)

var temporaryPatterns = []*regexp.Regexp{
	regexp.MustCompile(`/runtime-workspace/tmp-workspaces(?:/|$)`),
	regexp.MustCompile(`/\.(?:Chief|Mokusei)(?:-headless)?/tmp-workspaces(?:/|$)`),
	regexp.MustCompile(`(?i)^/(?:private/)?(?:tmp|var/tmp)/(?:chief|mokusei)-[^/]+(?:/|$)`),
	regexp.MustCompile(`(?i)^/(?:private/)?var/folders/[^/]+/[^/]+/T/(?:chief|mokusei)-[^/]+(?:/|$)`),
	regexp.MustCompile(`(?i)^[A-Za-z]:/(?:Windows/Temp|Users/[^/]+/AppData/Local/Temp)/(?:chief|mokusei)-[^/]+(?:/|$)`),
}

// ManagedStagingStem identifies both current and previously stored worktree
// directory names. It does not establish ownership of the worktree.
func ManagedStagingStem(name string) string {
	stem, ok := strings.CutPrefix(name, ".")
	if !ok {
		return ""
	}
	for _, suffix := range []string{stagingSuffix, legacyStagingSuffix} {
		if stem, ok := strings.CutSuffix(stem, suffix); ok {
			return stem
		}
	}
	return ""
}

func IsTemporaryWorkspacePath(path string) bool {
	path = filepath.ToSlash(filepath.Clean(path))
	for _, p := range temporaryPatterns {
		if p.MatchString(path) {
			return true
		}
	}
	return false
}

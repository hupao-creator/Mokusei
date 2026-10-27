package workspaces

import (
	"path/filepath"
	"regexp"
)

var temporaryPatterns = []*regexp.Regexp{
	regexp.MustCompile(`/runtime-workspace/tmp-workspaces(?:/|$)`),
	regexp.MustCompile(`/\.Mokusei(?:-headless)?/tmp-workspaces(?:/|$)`),
	regexp.MustCompile(`(?i)^/(?:private/)?(?:tmp|var/tmp)/mokusei-[^/]+(?:/|$)`),
	regexp.MustCompile(`(?i)^/(?:private/)?var/folders/[^/]+/[^/]+/T/mokusei-[^/]+(?:/|$)`),
	regexp.MustCompile(`(?i)^[A-Za-z]:/(?:Windows/Temp|Users/[^/]+/AppData/Local/Temp)/mokusei-[^/]+(?:/|$)`),
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

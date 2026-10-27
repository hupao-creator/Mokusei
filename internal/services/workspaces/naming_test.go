package workspaces

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"unicode"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func TestDirectoryNameSanitizesCallerLabels(t *testing.T) {
	for input, want := range map[string]string{
		"fix auth":            "fix-auth",
		"  Fix Auth Flow!  ":  "Fix-Auth-Flow",
		"fix/auth":            "fix-auth",
		"fix\\auth":           "fix-auth",
		"../escape":           "escape",
		".hidden":             "hidden",
		"..":                  "",
		"...":                 "",
		".":                   "",
		"/":                   "",
		"   ":                 "",
		"a\x00b\x1bc":         "a-b-c",
		"feature/branch_name": "feature-branch_name",
		// Unicode letters and digits survive instead of being discarded.
		"修复登录":                                 "修复登录",
		"修复登录 fix":                             "修复登录-fix",
		"修复/登录":                                "修复-登录",
		"Ｆｉｘ Ａｕｔｈ":                             "Fix-Auth", // NFKC full-width forms
		"a…b":                                  "a...b",    // NFKC ellipsis expands to three dots
		"e\u0301":                              "é",        // combining mark composes to NFC
		"ﬁx":                                   "fix",      // NFKC ligature
		"\u1112\u1161\u11ab\u1100\u1173\u11af": "한글",       // jamo compose to NFC
		"---":                                  "",
		"._-":                                  "_",
		"a🙂b":                                  "a-b",
	} {
		got := directoryName(input)
		if got != want {
			t.Fatalf("directoryName(%q) = %q, want %q", input, got, want)
		}
		if got != "" && !safeStagingLabel(got) {
			t.Fatalf("directoryName(%q) = %q is not a safe staging label", input, got)
		}
		for _, r := range got {
			if unicode.Is(unicode.M, r) {
				t.Fatalf("directoryName(%q) = %q contains combining mark %U", input, got, r)
			}
		}
	}
}

func TestDirectoryNameCapsAt48Runes(t *testing.T) {
	exact := strings.Repeat("汉", 48)
	if got := directoryName(exact); got != exact {
		t.Fatalf("48-rune label changed: %q", got)
	}
	over := strings.Repeat("汉", 49)
	got := directoryName(over)
	if got != strings.Repeat("汉", 48) || utf8.RuneCountInString(got) != 48 || len(got) != 48*3 {
		t.Fatalf("over-long label = %q (%d runes, %d bytes)", got, utf8.RuneCountInString(got), len(got))
	}
	// The cap applies before trailing-dot trimming, so the result can be shorter.
	truncated := directoryName(strings.Repeat("a", 47) + ".x")
	if truncated != strings.Repeat("a", 47) {
		t.Fatalf("trailing dot after truncation was not trimmed: %q", truncated)
	}
}

func TestDirectoryNameNormalizesToNFC(t *testing.T) {
	for _, input := range []string{"é", "e\u0301"} {
		if got := directoryName(input); got != "é" {
			t.Fatalf("directoryName(%q) = %q, want NFC é", input, got)
		}
	}
	if directoryName("\u4fee\u590d\u767b\u5f55") != directoryName("修复登录") {
		t.Fatal("NFC label is not idempotent")
	}
}

// slug is the repository/thread identity sanitizer, not the caller-label
// sanitizer. It must keep trimming only dashes or existing staging roots for
// dotted submodule paths move and their ownership proofs stop matching.
func TestSlugKeepsHistoricalDottedSubmoduleRoots(t *testing.T) {
	for input, want := range map[string]string{
		".hidden/repo": ".hidden-repo",
		"a.b":          "a.b",
		"...":          "...",
		"///":          "task",
		"修复登录":         "task",
	} {
		if got := slug(input); got != want {
			t.Fatalf("slug(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestGeneratedLabelIsStableForThreadIDs(t *testing.T) {
	if got, want := generatedLabel("0123456789abcdef"), "task-0123456789ab"; got != want {
		t.Fatalf("generatedLabel = %q, want %q", got, want)
	}
}

func TestPrepareForStartReportsWorktreeNameOutcome(t *testing.T) {
	root := t.TempDir()
	repo := filepath.Join(root, "project")
	if err := os.MkdirAll(repo, 0700); err != nil {
		t.Fatal(err)
	}
	git := func(args ...string) {
		command := exec.Command("git", args...)
		command.Dir = repo
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, output)
		}
	}
	git("init", "--quiet")
	if err := os.WriteFile(filepath.Join(repo, "fixture.txt"), []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	git("add", "fixture.txt")
	git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")
	manager := New(Paths{DefaultCwd: repo})
	enabled := true
	prepare := func(threadID, name string) Preparation {
		t.Helper()
		p, err := manager.PrepareForStart(context.Background(), repo, threadID, &model.WorktreeOptions{Enabled: &enabled, Name: name}, nil)
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	first := prepare("thread-owner-1", "修复 登录")
	if first.WorktreeName != "修复-登录" || !first.WorktreeNameAdjusted || !strings.Contains(first.WorktreeNameNotice, "was sanitized to") {
		t.Fatalf("sanitized preparation = %#v", first)
	}
	second := prepare("thread-owner-2", "修复 登录")
	if second.WorktreeName != "修复-登录-2" || !second.WorktreeNameAdjusted || !strings.Contains(second.WorktreeNameNotice, "collision") {
		t.Fatalf("collision preparation = %#v", second)
	}
	generated := prepare("thread-owner-3", "///")
	if !strings.HasPrefix(generated.WorktreeName, "task-thread-owner-") || !generated.WorktreeNameAdjusted || !strings.Contains(generated.WorktreeNameNotice, "no usable path-safe form") {
		t.Fatalf("fallback preparation = %#v", generated)
	}
	if strings.Contains(first.WorktreeNameNotice, "all candidate directories") {
		t.Fatalf("sanitization notice was diagnosed as fallback: %q", first.WorktreeNameNotice)
	}
}

func TestWorktreeNameOutcomeReportsEveryAdjustment(t *testing.T) {
	for _, test := range []struct {
		name      string
		requested string
		sanitized string
		effective string
		fallback  bool
		adjusted  bool
		contains  string
		forbidden string
	}{
		{"absent", "", "", "task-0123456789a-abcdef", false, false, "", ""},
		{"unchanged", "fix-auth", "fix-auth", "fix-auth", false, false, "", ""},
		{"unicode-unchanged", "修复登录", "修复登录", "修复登录", false, false, "", ""},
		{"sanitized", "fix auth", "fix-auth", "fix-auth", false, true, "was sanitized to", ""},
		{"truncated", strings.Repeat("a", 60), strings.Repeat("a", 48), strings.Repeat("a", 48), false, true, "48 runes", ""},
		{"collision", "fix-auth", "fix-auth", "fix-auth-2", false, true, "collision", "was sanitized to"},
		{"random-suffix", "fix-auth", "fix-auth", "fix-auth-a1b2", false, true, "short random suffix", "was sanitized to"},
		{"sanitized-collision", "fix auth", "fix-auth", "fix-auth-2", false, true, "was sanitized to", ""},
		{"fallback-empty", "!!!", "", "task-0123456789a-abcdef", true, true, "no usable path-safe form", "all candidate directories"},
		{"fallback-exhausted", "fix-auth", "fix-auth", "task-0123456789a-abcdef", true, true, "all candidate directories", "no usable path-safe form"},
	} {
		t.Run(test.name, func(t *testing.T) {
			adjusted, notice := worktreeNameOutcome(test.requested, test.sanitized, test.effective, test.fallback)
			if adjusted != test.adjusted {
				t.Fatalf("adjusted = %v, want %v (notice %q)", adjusted, test.adjusted, notice)
			}
			if test.contains != "" && !strings.Contains(notice, test.contains) {
				t.Fatalf("notice %q does not mention %q", notice, test.contains)
			}
			if test.forbidden != "" && strings.Contains(notice, test.forbidden) {
				t.Fatalf("notice %q wrongly mentions %q", notice, test.forbidden)
			}
			if !test.adjusted && notice != "" {
				t.Fatalf("unadjusted name carried notice %q", notice)
			}
		})
	}
}

func TestCreateStagingDeterministicCollisions(t *testing.T) {
	parent := filepath.Join(t.TempDir(), "staging")
	for attempt := 0; attempt < 8; attempt++ {
		path, err := createStaging(parent, "fix-auth", false)
		if err != nil {
			t.Fatalf("attempt %d: %v", attempt, err)
		}
		want := "fix-auth"
		if attempt > 0 {
			want = "fix-auth-" + strconv.Itoa(attempt+1)
		}
		if got := filepath.Base(path); got != want {
			t.Fatalf("attempt %d staging name = %q, want %q", attempt, got, want)
		}
	}
	// The ninth reuse must not hard-fail: it gets a short random suffix.
	ninth, err := createStaging(parent, "fix-auth", false)
	if err != nil {
		t.Fatalf("ninth collision failed instead of using a random suffix: %v", err)
	}
	if got := filepath.Base(ninth); !regexp.MustCompile(`^fix-auth-[0-9a-f]{4}$`).MatchString(got) {
		t.Fatalf("ninth staging name = %q, want fix-auth-<4 hex>", got)
	}
	tenth, err := createStaging(parent, "fix-auth", false)
	if err != nil {
		t.Fatalf("tenth collision failed: %v", err)
	}
	if got := filepath.Base(tenth); got == filepath.Base(ninth) || !regexp.MustCompile(`^fix-auth-[0-9a-f]{4}$`).MatchString(got) {
		t.Fatalf("tenth staging name = %q", got)
	}
}

func TestCreateStagingGeneratedNameKeepsRandomSuffix(t *testing.T) {
	parent := filepath.Join(t.TempDir(), "staging")
	path, err := createStaging(parent, "task-threadid12", true)
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^task-threadid12-[0-9a-f]{32}$`).MatchString(filepath.Base(path)) {
		t.Fatalf("generated staging name = %q", filepath.Base(path))
	}
}

func TestCreateStagingAcceptsUnicodeButRejectsUnsafeLabels(t *testing.T) {
	parent := filepath.Join(t.TempDir(), "staging")
	path, err := createStaging(parent, "修复登录", false)
	if err != nil {
		t.Fatalf("Unicode staging label rejected: %v", err)
	}
	if got := filepath.Base(path); got != "修复登录" {
		t.Fatalf("Unicode staging name = %q", got)
	}
	for _, label := range []string{"", ".", "..", ".hidden", "a.", "a/b", `a\b`, "a\x00b", "a\x1bb", "a\nb", "a b", "a🙂b"} {
		if _, err := createStaging(parent, label, false); err == nil {
			t.Fatalf("unsafe staging label %q was accepted", label)
		}
	}
}

func TestCreateStagingReportsCollisionAfterRandomFallback(t *testing.T) {
	parent := filepath.Join(t.TempDir(), "staging")
	for attempt := 0; attempt < 8; attempt++ {
		if _, err := createStaging(parent, "fix-auth", false); err != nil {
			t.Fatal(err)
		}
	}
	pinned := "deadbeef0123456789abcdef01234567"
	if err := os.Mkdir(filepath.Join(parent, "fix-auth-"+pinned[:4]), 0700); err != nil {
		t.Fatal(err)
	}
	_, err := createStagingWithRandom(parent, "fix-auth", false, func() (string, error) {
		return pinned, nil
	})
	if !errors.Is(err, errStagingCollision) {
		t.Fatalf("collision exhaustion = %v, want errStagingCollision", err)
	}
	if !strings.Contains(err.Error(), `"fix-auth"`) {
		t.Fatalf("collision error does not name the requested label: %v", err)
	}
}

package pi

import (
	"errors"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// Raw stderr is never forwarded: only diagnostic lines survive, and
// credential-shaped content inside them is redacted.
func TestDiagnosticTailKeepsOnlyCredentialFreeDiagnostics(t *testing.T) {
	tail := &diagnosticTail{limit: 256}
	if _, err := tail.Write([]byte("listening on socket /tmp/pi.sock\n")); err != nil {
		t.Fatal(err)
	}
	if _, err := tail.Write([]byte("Authorization: Bearer sk-live-abcdefghijklmnop\n")); err != nil {
		t.Fatal(err)
	}
	if _, err := tail.Write([]byte("token=opaquevalue123\n")); err != nil {
		t.Fatal(err)
	}
	if _, err := tail.Write([]byte("Error: Unknown provider \"opencode-go\".\n")); err != nil {
		t.Fatal(err)
	}
	message := tail.message()
	if !strings.Contains(message, `Unknown provider "opencode-go"`) {
		t.Fatalf("diagnostic line was dropped: %q", message)
	}
	for _, secret := range []string{"sk-live", "opaquevalue123", "Bearer", "listening"} {
		if strings.Contains(message, secret) {
			t.Fatalf("diagnostic tail kept %q: %q", secret, message)
		}
	}
	if strings.Contains(message, "\n") {
		t.Fatalf("diagnostic tail was not collapsed: %q", message)
	}
}

func TestDiagnosticTailRedactsCredentialInsideDiagnostic(t *testing.T) {
	tail := &diagnosticTail{limit: 256}
	if _, err := tail.Write([]byte("Error: Unknown provider \"opencode-go\" (api key sk-live-abcdefghijklmnop missing)")); err != nil {
		t.Fatal(err)
	}
	message := tail.message()
	if !strings.Contains(message, `Unknown provider "opencode-go"`) {
		t.Fatalf("selection cause was dropped: %q", message)
	}
	if strings.Contains(message, "sk-live") {
		t.Fatalf("credential leaked: %q", message)
	}
}

func TestDiagnosticTailBoundsAndKeepsPartialLines(t *testing.T) {
	tail := &diagnosticTail{limit: 64}
	if _, err := tail.Write([]byte(strings.Repeat("ignored line\n", 20) + "Error: model \"grok-4.7\" not found")); err != nil {
		t.Fatal(err)
	}
	message := tail.message()
	if !strings.HasSuffix(message, `model "grok-4.7" not found`) {
		t.Fatalf("unterminated diagnostic line was dropped: %q", message)
	}
	if len(message) > 512 {
		t.Fatalf("diagnostic tail exceeded its bound: %d", len(message))
	}
}

// A rejected provider must be named in the error and stay caller-correctable,
// so the bridge can answer 422 instead of a generic 500.
func TestSelectionFailureClassifiesRejectedSelection(t *testing.T) {
	cause := errors.New(`Pi RPC process exited: exit status 1; Pi said: Error: Unknown provider "opencode-go".`)
	err := selectionFailure(ThreadSettings{Provider: "opencode-go", Model: "grok-4.7"}, cause)
	message := err.Error()
	for _, want := range []string{"opencode-go", "grok-4.7", `Unknown provider "opencode-go"`, "local Pi catalog"} {
		if !strings.Contains(message, want) {
			t.Fatalf("selection failure does not mention %q: %s", want, message)
		}
	}
	var marked *plugin.ToolCallError
	if !errors.As(err, &marked) {
		t.Fatal("rejected selection did not keep the caller-error mark")
	}
	if !errors.Is(err, cause) {
		t.Fatal("selection failure dropped the native cause")
	}
}

func TestSelectionFailureKeepsStartupFaultsInternal(t *testing.T) {
	cause := errors.New("Pi RPC process exited: exit status 1; Pi said: Error: model runtime failed to initialize")
	err := selectionFailure(ThreadSettings{Provider: "opencode-go", Model: "grok-4.7"}, cause)
	var marked *plugin.ToolCallError
	if errors.As(err, &marked) {
		t.Fatalf("internal startup fault gained a caller mark: %v", err)
	}
	if !errors.Is(err, cause) || !strings.Contains(err.Error(), "grok-4.7") {
		t.Fatalf("startup fault lost its cause or context: %v", err)
	}
	plain := errors.New("Pi RPC process exited: exit status 1")
	if got := selectionFailure(ThreadSettings{}, plain); got != plain {
		t.Fatalf("unselected settings gained selection context: %v", got)
	}
}

func TestUnavailableSelectionIsCallerCorrectable(t *testing.T) {
	err := unavailableSelection("opencode-go", "grok-4.7")
	var marked *plugin.ToolCallError
	if !errors.As(err, &marked) {
		t.Fatal("unavailable selection did not keep the caller-error mark")
	}
	for _, want := range []string{"opencode-go", "grok-4.7", "login"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("unavailable selection does not mention %q: %s", want, err)
		}
	}
}

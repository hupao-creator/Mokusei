package artificialanalysis

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
)

type httpFailure int

func (e httpFailure) Error() string { return fmt.Sprintf("AA source HTTP %d", int(e)) }

func failureClass(err error) string {
	var network net.Error
	var path *os.PathError
	var httpStatus httpFailure
	switch {
	case errors.Is(err, context.Canceled):
		return "cancelled"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.As(err, &httpStatus):
		return "http"
	case errors.As(err, &network):
		if network.Timeout() {
			return "timeout"
		}
		return "network"
	case errors.As(err, &path):
		return "storage"
	default:
		return "unavailable"
	}
}

// DiagnosticSummary is the composition boundary's closed log vocabulary. Native
// errors, model names, URLs, paths and arbitrary callback fields stay private.
func DiagnosticSummary(fields map[string]any) error {
	out := map[string]any{}
	for key, value := range fields {
		switch key {
		case "class":
			switch s := value.(type) {
			case string:
				switch s {
				case "cancelled", "timeout", "http", "network", "storage", "unavailable", "invalid-document", "identity-mismatch":
					out[key] = s
				}
			}
		case "catalogId":
			if s, ok := value.(string); ok && (s == "codex" || s == "claude" || s == "pi" || s == "opencode") {
				out[key] = s
			}
		case "reason":
			if s, ok := value.(string); ok && (s == "contribution-byte-limit" || s == "no-resolvable-identities" || s == "facts-unavailable") {
				out[key] = s
			}
		case "retained":
			if b, ok := value.(bool); ok {
				out[key] = b
			}
		case "durationMs":
			if n, ok := value.(int64); ok && n >= 0 {
				out[key] = n
			}
		case "targets", "identities", "matchedReleases", "indexConfigurations":
			if n, ok := value.(int); ok && n >= 0 && n <= 10000 {
				out[key] = n
			}
		}
	}
	data, _ := json.Marshal(out)
	return errors.New(string(data))
}

package diagnostics

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"
)

const toolPayloadLimit = 256 * 1024
const toolDecodeLimit = 8 * 1024 * 1024

type toolPayload struct {
	Status         string          `json:"status"`
	OriginalBytes  int             `json:"originalBytes"`
	SanitizedBytes int             `json:"sanitizedBytes"`
	StoredBytes    int             `json:"storedBytes"`
	Redactions     int             `json:"redactions"`
	Omissions      int             `json:"omissions"`
	SHA256         string          `json:"sanitizedSha256,omitempty"`
	JSON           json.RawMessage `json:"json,omitempty"`
	Preview        string          `json:"jsonPrefix,omitempty"`
	Structure      any             `json:"structure,omitempty"`
	StructureBytes int             `json:"structureBytes,omitempty"`
}

var credentialField = regexp.MustCompile(`(?i)^(authorization|proxyauthorization|cookie|setcookie|password|passwd|pwd|secret|clientsecret|apikey|accesstoken|refreshtoken|idtoken|token|credential|credentials|privatekey)$`)
var credentialKeyNormalizer = strings.NewReplacer("_", "", "-", "", " ", "")
var credentialText = []*regexp.Regexp{
	regexp.MustCompile(`(?is)-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----.*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----|$)`),
	regexp.MustCompile(`(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+`),
	regexp.MustCompile(`\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|AKIA[A-Z0-9]{16})\b`),
	regexp.MustCompile(`(?i)\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|token|password|passwd|pwd|client[_-]?secret|secret|private[_-]?key|credentials?|(?:proxy[_-]?)?authorization|(?:set[_-]?)?cookie)["']?\s*[=:]\s*["']?[^\s"'&,;<>]+`),
	regexp.MustCompile(`(?i)https?://[^\s/@]+:[^\s/@]+@`),
}

func redactToolText(s string) (string, int) {
	n := 0
	for _, pattern := range credentialText {
		s = pattern.ReplaceAllStringFunc(s, func(string) string { n++; return "[REDACTED]" })
	}
	return s, n
}

func captureToolPayload(raw json.RawMessage) toolPayload {
	p := toolPayload{OriginalBytes: len(raw)}
	if len(raw) == 0 {
		p.Status = "missing"
		return p
	}
	if len(raw) > toolDecodeLimit {
		p.Status = "omitted-over-decode-limit"
		return p
	}
	if !json.Valid(raw) {
		// Malformed text cannot be safely redacted structurally. Do not leak an
		// unparsed prefix just to make a failed boundary appear fully observed.
		p.Status = "omitted-invalid-json"
		return p
	}
	var value any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if decoder.Decode(&value) != nil {
		p.Status = "omitted-invalid-json"
		return p
	}
	var sanitize func(any, int) any
	sanitize = func(v any, depth int) any {
		if depth > 64 {
			p.Omissions++
			return "[omitted:depth-limit]"
		}
		switch v := v.(type) {
		case map[string]any:
			out := make(map[string]any, len(v))
			for key, child := range v {
				normalized := strings.ToLower(credentialKeyNormalizer.Replace(key))
				if credentialField.MatchString(normalized) || strings.HasSuffix(normalized, "password") || strings.HasSuffix(normalized, "secret") || strings.HasSuffix(normalized, "apikey") {
					p.Redactions++
					out[key] = "[REDACTED]"
				} else {
					out[key] = sanitize(child, depth+1)
				}
			}
			return out
		case []any:
			for i := range v {
				v[i] = sanitize(v[i], depth+1)
			}
			return v
		case string:
			// Paged evidence tools return JSON inside a text field. Preserve its
			// string contract while applying the same structural credential policy.
			if len(v) <= toolDecodeLimit && (strings.HasPrefix(strings.TrimSpace(v), "{") || strings.HasPrefix(strings.TrimSpace(v), "[")) && json.Valid([]byte(v)) {
				var nested any
				d := json.NewDecoder(strings.NewReader(v))
				d.UseNumber()
				if d.Decode(&nested) == nil {
					encoded, _ := json.Marshal(sanitize(nested, depth+1))
					return string(encoded)
				}
			}
			text, n := redactToolText(v)
			p.Redactions += n
			return text
		default:
			return v
		}
	}
	sanitized := sanitize(value, 0)
	data, _ := json.Marshal(sanitized)
	p.SanitizedBytes = len(data)
	hash := sha256.Sum256(data)
	p.SHA256 = hex.EncodeToString(hash[:])
	p.Status = "complete"
	if p.Omissions != 0 {
		p.Status = "partial-depth-limit"
	}
	if len(data) > toolPayloadLimit {
		p.Status = "truncated"
		p.Preview = utf8Prefix(string(data), toolPayloadLimit)
		p.StoredBytes = len(p.Preview)
		// A large early HTML/text field must not hide later IDs, pagination or
		// per-item status entirely. This bounded structural sample supplements,
		// rather than masquerades as, the retained JSON prefix.
		nodes := 128
		p.Structure = toolPayloadStructure(sanitized, 0, &nodes)
		structure, _ := json.Marshal(p.Structure)
		p.StructureBytes = len(structure)
	} else {
		p.JSON = data
		p.StoredBytes = len(data)
	}
	return p
}

func toolPayloadStructure(value any, depth int, nodes *int) any {
	if *nodes <= 0 {
		return map[string]any{"omitted": "structure-budget"}
	}
	*nodes = *nodes - 1
	if depth > 6 {
		return map[string]any{"omitted": "structure-depth"}
	}
	switch value := value.(type) {
	case map[string]any:
		keys := make([]string, 0, len(value))
		for key := range value {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		fields := []any{}
		for _, key := range keys {
			if *nodes <= 0 {
				break
			}
			fields = append(fields, map[string]any{"key": utf8Prefix(key, 128), "keyTruncated": len(key) > 128, "value": toolPayloadStructure(value[key], depth+1, nodes)})
		}
		return map[string]any{"kind": "object", "count": len(keys), "fields": fields, "fieldsOmitted": len(keys) - len(fields)}
	case []any:
		items := []any{}
		for _, item := range value {
			if *nodes <= 0 || len(items) >= 8 {
				break
			}
			items = append(items, toolPayloadStructure(item, depth+1, nodes))
		}
		return map[string]any{"kind": "array", "count": len(value), "items": items, "itemsOmitted": len(value) - len(items)}
	case string:
		return map[string]any{"kind": "string", "bytes": len(value), "prefix": utf8Prefix(value, 128), "truncated": len(value) > 128}
	case json.Number:
		text := value.String()
		return map[string]any{"kind": "number", "bytes": len(text), "prefix": utf8Prefix(text, 128), "truncated": len(text) > 128}
	default:
		return value
	}
}

func utf8Prefix(s string, limit int) string {
	if len(s) <= limit {
		return s
	}
	s = s[:limit]
	for !utf8.ValidString(s) {
		s = s[:len(s)-1]
	}
	return s
}

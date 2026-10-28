package attachments

import (
	"bytes"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

var mediaTypes = map[string]string{
	".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp",
	".pdf": "application/pdf", ".txt": "text/plain", ".log": "text/plain", ".md": "text/markdown", ".markdown": "text/markdown",
	".json": "application/json", ".jsonl": "application/x-ndjson", ".csv": "text/csv", ".ts": "text/typescript", ".tsx": "text/typescript-jsx",
	".js": "text/javascript", ".jsx": "text/javascript-jsx", ".py": "text/x-python", ".rs": "text/x-rust", ".go": "text/x-go",
	".java": "text/x-java", ".swift": "text/x-swift", ".html": "text/html", ".css": "text/css", ".xml": "application/xml",
	".yaml": "application/yaml", ".yml": "application/yaml", ".toml": "application/toml",
}

func MimeTypeForPath(path string) string {
	if mime, ok := mediaTypes[strings.ToLower(filepath.Ext(strings.ReplaceAll(path, "\\", "/")))]; ok {
		return mime
	}
	return "application/octet-stream"
}
func KindForMimeType(mime string) string {
	if strings.HasPrefix(mime, "image/") {
		return "image"
	}
	if strings.HasPrefix(mime, "text/") || mime == "application/pdf" || mime == "application/json" || mime == "application/x-ndjson" || mime == "application/xml" || mime == "application/yaml" || mime == "application/toml" {
		return "document"
	}
	return "file"
}
func sizeLimit(mime string) int64 {
	if strings.HasPrefix(mime, "image/") {
		return 20 * 1024 * 1024
	}
	if mime == "application/pdf" {
		return 32 * 1024 * 1024
	}
	return 50 * 1024 * 1024
}

func Policy() model.AttachmentPolicy {
	return model.AttachmentPolicy{ImageBytes: 20 * 1024 * 1024, PDFBytes: 32 * 1024 * 1024,
		FileBytes: 50 * 1024 * 1024, MessageBytes: MaxMessageBytes, MessageCount: MaxMessageCount}
}

func sniffMime(b []byte) string {
	switch {
	case len(b) >= 8 && bytes.Equal(b[:4], []byte{0x89, 'P', 'N', 'G'}):
		return "image/png"
	case len(b) >= 3 && bytes.Equal(b[:3], []byte{0xff, 0xd8, 0xff}):
		return "image/jpeg"
	case len(b) >= 4 && string(b[:4]) == "GIF8":
		return "image/gif"
	case len(b) >= 12 && string(b[:4]) == "RIFF" && string(b[8:12]) == "WEBP":
		return "image/webp"
	case len(b) >= 4 && string(b[:4]) == "%PDF":
		return "application/pdf"
	default:
		return "application/octet-stream"
	}
}
func extensionFor(mime string) string {
	switch mime {
	case "image/png":
		return ".png"
	case "image/jpeg":
		return ".jpg"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	case "application/pdf":
		return ".pdf"
	default:
		return ".bin"
	}
}

var safeExt = regexp.MustCompile(`(?i)^\.[a-z0-9]{1,16}$`)

func sanitizeName(raw, extension string) string {
	name := strings.TrimSpace(filepath.Base(strings.ReplaceAll(raw, "\\", "/")))
	name = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return '_'
		}
		return r
	}, name)
	// A single-segment dotfile has no separate stem/extension. Once the
	// leading dots are removed, appending that segment would duplicate it.
	if strings.HasPrefix(name, ".") && !strings.Contains(strings.TrimLeft(name, "."), ".") &&
		strings.EqualFold(extension, filepath.Ext(name)) {
		extension = ""
	}
	name = strings.TrimLeft(name, ".")
	if name == "" {
		name = "file"
	}
	if !safeExt.MatchString(extension) {
		extension = ""
	}
	extension = strings.ToLower(extension)
	stem := strings.TrimSuffix(name, filepath.Ext(name))
	if stem == "" {
		stem = "file"
	}
	// Keep the stored filename inside the filesystem's byte limit as well as
	// the display limit, without splitting a Unicode sequence.
	for len(stem)+len(extension) > 120 {
		_, n := utf8.DecodeLastRuneInString(stem)
		stem = stem[:len(stem)-n]
	}
	return stem + extension
}

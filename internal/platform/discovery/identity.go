package discovery

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
)

// Identity binds in-memory facts to the native environment and file generation.
// No environment values, credentials or file contents are stored in the key or
// logged. Callers list their own native configuration files; discovery does not
// interpret another engine's account format. TTL/manual refresh still covers
// changes not observable through files, such as keychain and remote accounts.
func Identity(environment map[string]string, paths ...string) string {
	hash := sha256.New()
	encoder := json.NewEncoder(hash)
	_ = encoder.Encode(environment)
	for _, path := range paths {
		_ = encoder.Encode(path)
		if canonical, err := filepath.EvalSymlinks(path); err == nil {
			_ = encoder.Encode(canonical)
		}
		if info, err := os.Stat(path); err == nil {
			_ = encoder.Encode([]any{info.Size(), info.ModTime().UnixNano(), info.Mode()})
		} else {
			_ = encoder.Encode("unavailable")
		}
	}
	return hex.EncodeToString(hash.Sum(nil))
}

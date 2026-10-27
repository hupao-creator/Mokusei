package workspaces

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"
)

// Directory identity deliberately excludes mutable mtime/ctime. Darwin's
// birthtime distinguishes replacement even when an inode is reused.
type directoryIdentity struct {
	Dev       string `json:"dev"`
	Ino       string `json:"ino"`
	Birthtime string `json:"birthtime"`
}

func identityOf(info os.FileInfo) (directoryIdentity, error) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return directoryIdentity{}, errors.New("filesystem identity unavailable")
	}
	birth := "0"
	// Keep the portable source buildable on Unix while retaining Darwin birthtime.
	v := reflect.ValueOf(stat).Elem().FieldByName("Birthtimespec")
	if v.IsValid() {
		birth = fmt.Sprintf("%d.%09d", v.FieldByName("Sec").Int(), v.FieldByName("Nsec").Int())
	}
	return directoryIdentity{fmt.Sprint(stat.Dev), fmt.Sprint(stat.Ino), birth}, nil
}
func directoryID(path string) (directoryIdentity, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return directoryIdentity{}, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return directoryIdentity{}, fmt.Errorf("not a physical directory: %s", path)
	}
	return identityOf(info)
}
func assertIdentity(path string, want directoryIdentity) error {
	got, err := directoryID(path)
	if err != nil {
		return err
	}
	if got != want {
		return fmt.Errorf("directory identity changed; retained: %s", path)
	}
	return nil
}
func privateDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("private staging path is not a directory: %s", path)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0077 != 0 {
		return fmt.Errorf("staging root must be owned by current user and owner-only: %s", path)
	}
	return nil
}
func canonical(path string) (string, error) {
	if !filepath.IsAbs(path) || strings.ContainsRune(path, 0) {
		return "", fmt.Errorf("path must be absolute: %q", path)
	}
	return filepath.EvalSymlinks(filepath.Clean(path))
}
func within(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)) && !filepath.IsAbs(rel)
}
func resolve(root, path string) string {
	if filepath.IsAbs(path) {
		return filepath.Clean(path)
	}
	return filepath.Join(root, path)
}
func exists(path string) (bool, error) {
	_, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, syscall.ENOTDIR) {
		return false, nil
	}
	return err == nil, err
}
func removeEmptyDirectory(path string) error { return syscall.Rmdir(path) }
func randomID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// O_NOFOLLOW and pre/post descriptor identities reject a replaced pointer,
// symlink, FIFO, device or oversized metadata file without blocking on it.
func readRegular(path string, max int) ([]byte, error) {
	before, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !before.Mode().IsRegular() || before.Size() > int64(max) {
		return nil, fmt.Errorf("not bounded regular metadata: %s", path)
	}
	beforeID, err := identityOf(before)
	if err != nil {
		return nil, err
	}
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	check := func() error {
		info, e := f.Stat()
		if e != nil {
			return e
		}
		id, e := identityOf(info)
		if e != nil {
			return e
		}
		if !info.Mode().IsRegular() || info.Size() > int64(max) || id != beforeID {
			return fmt.Errorf("metadata identity/size changed: %s", path)
		}
		return nil
	}
	if err = check(); err != nil {
		return nil, err
	}
	b, err := io.ReadAll(io.LimitReader(f, int64(max)+1))
	if err != nil {
		return nil, err
	}
	if len(b) > max {
		return nil, fmt.Errorf("metadata exceeds limit: %s", path)
	}
	if err = check(); err != nil {
		return nil, err
	}
	return b, nil
}
func atomicPrivate(path string, body []byte) error {
	parent := filepath.Dir(path)
	if err := os.MkdirAll(parent, 0700); err != nil {
		return err
	}
	if err := privateDirectory(parent); err != nil {
		return err
	}
	parentID, err := directoryID(parent)
	if err != nil {
		return err
	}
	if present, err := exists(path); err != nil {
		return err
	} else if present {
		info, e := os.Lstat(path)
		if e != nil {
			return e
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !info.Mode().IsRegular() || !ok || st.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0077 != 0 {
			return fmt.Errorf("unsafe registry file: %s", path)
		}
	}
	f, err := os.CreateTemp(parent, ".worktree-registry-")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
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
	if err = assertIdentity(parent, parentID); err != nil {
		return err
	}
	if err = os.Rename(name, path); err != nil {
		return err
	}
	d, err := os.Open(parent)
	if err != nil {
		return err
	}
	return errors.Join(d.Sync(), d.Close())
}

var errStagingCollision = errors.New("no unique worktree staging directory available")

// safeStagingLabel mirrors directoryName's character class at the filesystem
// boundary. It is a real check, not just a structural one: a raw label may not
// start or end with "." and may only contain Unicode letters/digits and "._-".
func safeStagingLabel(label string) bool {
	if label == "" || label == "." || label == ".." || filepath.Base(label) != label {
		return false
	}
	first, _ := utf8.DecodeRuneInString(label)
	if first == '.' || strings.HasSuffix(label, ".") {
		return false
	}
	for _, r := range label {
		if r == '/' || r == '\\' || r == 0 || unicode.IsControl(r) {
			return false
		}
		if !(unicode.IsLetter(r) || unicode.IsDigit(r) || r == '.' || r == '_' || r == '-') {
			return false
		}
	}
	return true
}

func createStaging(parent, label string, randomSuffix bool) (string, error) {
	return createStagingWithRandom(parent, label, randomSuffix, randomID)
}

func createStagingWithRandom(parent, label string, randomSuffix bool, random func() (string, error)) (string, error) {
	if !safeStagingLabel(label) {
		return "", fmt.Errorf("invalid staging label %q: use Unicode letters, digits, '.', '_' or '-' with no leading dot", label)
	}
	parentParent, err := canonical(filepath.Dir(parent))
	if err != nil {
		return "", err
	}
	if err = os.Mkdir(parent, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return "", err
	}
	if err = privateDirectory(parent); err != nil {
		return "", err
	}
	id, err := directoryID(parent)
	if err != nil {
		return "", err
	}
	real, err := canonical(parent)
	if err != nil {
		return "", err
	}
	if filepath.Dir(real) != parentParent {
		return "", errors.New("staging parent escaped expected directory")
	}
	if err = assertIdentity(parent, id); err != nil {
		return "", err
	}
	// Caller-chosen labels try the deterministic "-2".."-8" suffixes first, then
	// a short random suffix, so reusing a name never hard-fails just because the
	// first eight historical worktrees still exist. Generated names keep the
	// original single random 32-hex suffix.
	attempts := 8
	if !randomSuffix {
		attempts = 16
	}
	for attempt := 0; attempt < attempts; attempt++ {
		name, e := stagingCandidateName(label, attempt, randomSuffix, random)
		if e != nil {
			return "", e
		}
		path := filepath.Join(real, name)
		e = assertIdentity(parent, id)
		if e != nil {
			return "", e
		}
		if e = os.Mkdir(path, 0700); errors.Is(e, os.ErrExist) {
			continue
		} else if e != nil {
			return "", e
		}
		if e = assertIdentity(parent, id); e == nil {
			var got string
			got, e = canonical(path)
			if e == nil && (got != path || filepath.Dir(got) != real) {
				e = errors.New("staging path escaped private root")
			}
		}
		if e != nil {
			return "", errors.Join(e, os.Remove(path))
		}
		return path, nil
	}
	return "", fmt.Errorf("%w for requested label %q", errStagingCollision, label)
}

func stagingCandidateName(label string, attempt int, randomSuffix bool, random func() (string, error)) (string, error) {
	if randomSuffix {
		suffix, err := random()
		if err != nil {
			return "", err
		}
		return label + "-" + suffix, nil
	}
	if attempt < 8 {
		if attempt == 0 {
			return label, nil
		}
		return label + "-" + strconv.Itoa(attempt+1), nil
	}
	suffix, err := random()
	if err != nil {
		return "", err
	}
	if len(suffix) < 4 {
		return "", errors.New("random suffix too short")
	}
	return label + "-" + suffix[:4], nil
}
func ensureDirectoryPath(root, target string, id directoryIdentity) error {
	if !within(root, target) {
		return errors.New("execution directory escapes worktree")
	}
	rel, _ := filepath.Rel(root, target)
	current := root
	if rel == "." {
		return assertIdentity(root, id)
	}
	for _, segment := range strings.Split(rel, string(os.PathSeparator)) {
		if err := assertIdentity(root, id); err != nil {
			return err
		}
		current = filepath.Join(current, segment)
		if err := os.Mkdir(current, 0755); err != nil && !errors.Is(err, os.ErrExist) {
			return err
		}
		if _, err := directoryID(current); err != nil {
			return err
		}
		got, err := canonical(current)
		if err != nil {
			return err
		}
		if !within(root, got) {
			return errors.New("execution directory symlink escaped worktree")
		}
	}
	return nil
}

// Package profile owns the private runtime discovery files and the single-writer
// lease. Call Acquire before opening any store in the profile.
package profile

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

type Options struct {
	DataDir string
	HomeDir string
}
type Profile struct {
	DataDir       string `json:"dataDir"`
	WorkspaceRoot string `json:"workspaceRoot"`
	DiscoveryPath string `json:"discoveryPath"`
	LockPath      string `json:"lockPath"`
	ReceiptsPath  string `json:"receiptsPath"`
	homeDir       string
}
type Connection struct {
	Port            int    `json:"port"`
	Token           string `json:"token"`
	Epoch           string `json:"epoch"`
	ProtocolVersion int    `json:"protocolVersion"`
	PID             int    `json:"pid"`
	DataDir         string `json:"dataDir"`
}

func Resolve(options Options) (Profile, error) {
	home := options.HomeDir
	if home == "" {
		var err error
		home, err = os.UserHomeDir()
		if err != nil {
			return Profile{}, err
		}
	}
	var appData string
	switch runtime.GOOS {
	case "darwin":
		appData = filepath.Join(home, "Library", "Application Support")
	case "windows":
		appData = os.Getenv("APPDATA")
		if appData == "" {
			appData = filepath.Join(home, "AppData", "Roaming")
		}
	default:
		appData = os.Getenv("XDG_CONFIG_HOME")
		if appData == "" {
			appData = filepath.Join(home, ".config")
		}
	}
	path := options.DataDir
	if path == "" {
		path = os.Getenv("MOKUSEI_RUNTIME_DATA_DIR")
	}
	if path == "" {
		path = filepath.Join(appData, "Mokusei")
	}
	dataDir, err := canonicalPath(path)
	if err != nil {
		return Profile{}, err
	}
	digest := sha256.Sum256([]byte(dataDir))
	workspace, err := canonicalPath(filepath.Join(home, ".Mokusei", "profiles", hex.EncodeToString(digest[:]), "runtime-workspace"))
	if err != nil {
		return Profile{}, err
	}
	private := filepath.Join(dataDir, "runtime")
	return Profile{DataDir: dataDir, WorkspaceRoot: workspace, DiscoveryPath: filepath.Join(private, "connection.json"), LockPath: filepath.Join(private, "owner.json"), ReceiptsPath: filepath.Join(private, "receipts.json"), homeDir: home}, nil
}

// Refresh resolves paths again after previously missing directories may have
// been created. Keep the selected home when deriving the workspace identity.
func Refresh(p Profile) (Profile, error) {
	return Resolve(Options{DataDir: p.DataDir, HomeDir: p.homeDir})
}

func canonicalPath(path string) (string, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	resolved, err := existingPath(absolute)
	if err == nil {
		return resolved, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	parent := filepath.Dir(absolute)
	if parent == absolute {
		return absolute, nil
	}
	resolved, err = canonicalPath(parent)
	if err != nil {
		return "", err
	}
	return filepath.Join(resolved, filepath.Base(absolute)), nil
}

func Prepare(p Profile) error {
	if runtime.GOOS == "windows" {
		return verifyPrivatePlatform(filepath.Dir(p.DiscoveryPath), true)
	}
	if err := os.MkdirAll(p.DataDir, 0700); err != nil {
		return err
	}
	directory := filepath.Dir(p.DiscoveryPath)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(directory)
	if err != nil {
		return err
	}
	if !info.IsDir() || !ownedByCurrentUser(info) {
		return model.NewError("UNSAFE_PROFILE", "Runtime metadata directory must belong to the current account")
	}
	if err = os.Chmod(directory, 0700); err != nil {
		return err
	}
	return verifyPrivatePlatform(directory, true)
}

// AtomicWrite writes a private file, syncs its contents, atomically renames it,
// and syncs the directory. A failed directory sync is deliberately an error:
// receipt admission must fail closed after an uncertain rename.
func AtomicWrite(path string, data []byte) error {
	file, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if err = file.Chmod(0600); err == nil {
		_, err = file.Write(data)
	}
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(temporary, path); err != nil {
		return err
	}
	if runtime.GOOS != "windows" {
		directory, openErr := os.Open(filepath.Dir(path))
		if openErr != nil {
			return openErr
		}
		syncErr := directory.Sync()
		closeErr = directory.Close()
		if syncErr != nil {
			return syncErr
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}
func WritePrivateJSON(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return AtomicWrite(path, data)
}
func ReadPrivateJSON(path string, value any) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() > 64*1024 || !ownedByCurrentUser(info) || (runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0) {
		return model.NewError("UNSAFE_PROFILE", "Runtime metadata must be a private file owned by the current account")
	}
	if err = verifyPrivatePlatform(path, false); err != nil {
		return err
	}
	// Open without following a last-component symlink, and revalidate the opened
	// file to close the lstat/open substitution window.
	file, err := openPrivateFile(path)
	if err != nil {
		return err
	}
	defer file.Close()
	actual, err := file.Stat()
	if err != nil {
		return err
	}
	if !os.SameFile(info, actual) {
		return model.NewError("UNSAFE_PROFILE", "Runtime metadata changed while being read")
	}
	data, err := io.ReadAll(io.LimitReader(file, 64*1024+1))
	if err != nil {
		return err
	}
	if len(data) > 64*1024 {
		return model.NewError("UNSAFE_PROFILE", "Runtime metadata exceeds its size limit")
	}
	return json.Unmarshal(data, value)
}

func ReadConnection(p Profile) (*Connection, error) {
	var value Connection
	err := ReadPrivateJSON(p.DiscoveryPath, &value)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if value.Port < 1 || value.Port > 65535 || len(value.Token) < 32 || value.Epoch == "" || value.ProtocolVersion < 1 || value.PID < 1 || value.DataDir != p.DataDir {
		return nil, model.NewError("INVALID_DISCOVERY", "Runtime discovery metadata is invalid or belongs to another profile")
	}
	return &value, nil
}
func PublishConnection(p Profile, value Connection) error {
	return WritePrivateJSON(p.DiscoveryPath, value)
}
func RemoveConnection(p Profile, epoch string) error {
	value, err := ReadConnection(p)
	if err != nil {
		return err
	}
	if value != nil && value.Epoch == epoch {
		err = os.Remove(p.DiscoveryPath)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	return nil
}
func HasLiveOwner(p Profile) (bool, error) {
	var owner struct {
		PID int `json:"pid"`
	}
	err := ReadPrivateJSON(p.LockPath, &owner)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return IsProcessAlive(owner.PID), nil
}
func StartupErrorPath(p Profile) string {
	return filepath.Join(filepath.Dir(p.DiscoveryPath), "startup-error.json")
}
func RecordStartupFailure(p Profile, cause error) error {
	message := "Runtime startup failed"
	if cause != nil {
		message = cause.Error()
	}
	if len(message) > 4096 {
		message = message[:4096]
	}
	return WritePrivateJSON(StartupErrorPath(p), map[string]any{"at": time.Now().UnixMilli(), "pid": os.Getpid(), "message": message})
}

type Ownership struct {
	Epoch      string
	OwnerToken string
	profile    Profile
	guard      net.Listener
	once       sync.Once
	releaseErr error
}

// GuardPort has exactly the identity mapping used by the former runtime. A
// collision is an ownership error; choosing a second port could admit writers.
func GuardPort(p Profile) int {
	digest := sha256.Sum256([]byte(p.DataDir))
	return 20000 + int(binary.BigEndian.Uint32(digest[:4])%40000)
}

func currentIdentity(p Profile) error {
	current, err := canonicalPath(p.DataDir)
	if err != nil {
		return err
	}
	if current != p.DataDir {
		return model.NewError("STALE_PROFILE", "The profile path changed identity; resolve it again before acquiring ownership")
	}
	return nil
}

func acquireGuard(p Profile) (net.Listener, error) {
	guard, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", GuardPort(p)))
	if err != nil {
		return nil, model.NewError("PROFILE_IN_USE", "The runtime profile is already owned, or its exclusive ownership port is occupied")
	}
	success := false
	defer func() {
		if !success {
			guard.Close()
		}
	}()
	if err = currentIdentity(p); err != nil {
		return nil, err
	}
	var previous struct {
		PID int `json:"pid"`
	}
	err = ReadPrivateJSON(p.LockPath, &previous)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err == nil && IsProcessAlive(previous.PID) {
		return nil, model.NewError("PROFILE_IN_USE", "A live process owns this runtime profile")
	}
	success = true
	return guard, nil
}

// WithExclusiveAccess excludes runtime owners while an existing profile is
// moved or otherwise maintained. It writes no ownership metadata, so closing
// the guard does not depend on the directory surviving the operation.
func WithExclusiveAccess(p Profile, operation func() error) (err error) {
	guard, err := acquireGuard(p)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, guard.Close()) }()
	// A missing path has no stable filesystem spelling yet. Do not let an
	// operation act on a case alias created after its guard was selected.
	if _, err = os.Stat(p.DataDir); err != nil {
		return err
	}
	if err = currentIdentity(p); err != nil {
		return err
	}
	return operation()
}

func Acquire(p Profile) (*Ownership, error) {
	guard, err := acquireGuard(p)
	if err != nil {
		return nil, err
	}
	success := false
	defer func() {
		if !success {
			guard.Close()
		}
	}()
	if err = Prepare(p); err != nil {
		return nil, err
	}
	// Two unresolved case aliases can initially select different guards. Only
	// the spelling the filesystem created may proceed to publish an owner.
	if err = currentIdentity(p); err != nil {
		return nil, err
	}
	token, err := randomHex(32)
	if err != nil {
		return nil, err
	}
	epoch, err := newUUID()
	if err != nil {
		return nil, err
	}
	owner := &Ownership{Epoch: epoch, OwnerToken: token, profile: p, guard: guard}
	if err = WritePrivateJSON(p.LockPath, map[string]any{"pid": os.Getpid(), "ownerToken": token, "epoch": epoch}); err != nil {
		return nil, err
	}
	go func() {
		for {
			conn, acceptErr := guard.Accept()
			if acceptErr != nil {
				return
			}
			conn.Close()
		}
	}()
	success = true
	return owner, nil
}
func (o *Ownership) Release() error {
	o.once.Do(func() {
		var current struct {
			OwnerToken string `json:"ownerToken"`
		}
		err := ReadPrivateJSON(o.profile.LockPath, &current)
		if errors.Is(err, os.ErrNotExist) {
			o.releaseErr = model.NewError("OWNERSHIP_LOST", "Runtime ownership metadata disappeared before release")
			return
		}
		if err != nil {
			o.releaseErr = err
			return
		}
		if current.OwnerToken == o.OwnerToken {
			o.releaseErr = os.Remove(o.profile.LockPath)
			if errors.Is(o.releaseErr, os.ErrNotExist) {
				o.releaseErr = model.NewError("OWNERSHIP_LOST", "Runtime ownership metadata changed during release")
			}
		} else {
			o.releaseErr = model.NewError("OWNERSHIP_LOST", "Runtime ownership metadata belongs to another generation")
		}
		if o.releaseErr == nil {
			o.releaseErr = o.guard.Close()
		}
	})
	return o.releaseErr
}
func randomHex(n int) (string, error) {
	data := make([]byte, n)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return hex.EncodeToString(data), nil
}
func newUUID() (string, error) {
	data := make([]byte, 16)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	data[6] = (data[6] & 15) | 64
	data[8] = (data[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", data[:4], data[4:6], data[6:8], data[8:10], data[10:]), nil
}

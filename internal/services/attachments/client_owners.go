package attachments

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// This envelope is shared with RuntimeDraftStore. Attachment references and the
// opaque client value are replaced in one atomic write; there is no second,
// eventually consistent copy of the draft's ownership.
type clientDraft struct {
	Version       int             `json:"version"`
	Scope         json.RawMessage `json:"scope"`
	AttachmentIDs []string        `json:"attachmentIDs"`
	Value         json.RawMessage `json:"value"`
}

// Native draft readers publish a separate live-owner pin before returning a
// restored value. The shared gate makes read-and-pin atomic with collection.
// These process-scoped pins are references, not another copy of draft content.
func (r *Repository) lockClientOwnership(ctx context.Context) (func(), error) {
	if r.clientRoot == "" {
		return func() {}, nil
	}
	directory := filepath.Join(r.clientRoot, "client-attachment-leases")
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	if err := privateClientDirectory(directory); err != nil {
		return nil, err
	}
	path := filepath.Join(directory, "ownership.lock")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0600)
	if err != nil {
		return nil, err
	}
	if err = validClientLock(file, path); err != nil {
		file.Close()
		return nil, err
	}
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return func() { _ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN); _ = file.Close() }, nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) && !errors.Is(err, syscall.EINTR) {
			file.Close()
			return nil, err
		}
		select {
		case <-ctx.Done():
			file.Close()
			return nil, ctx.Err()
		case <-deadline.C:
			file.Close()
			return nil, errors.New("client draft ownership is busy; attachment collection deferred")
		case <-ticker.C:
		}
	}
}

func validClientLock(file *os.File, path string) error {
	opened, err := file.Stat()
	if err != nil {
		return err
	}
	named, err := os.Lstat(path)
	if err != nil {
		return err
	}
	stat, ok := opened.Sys().(*syscall.Stat_t)
	if !opened.Mode().IsRegular() || opened.Mode().Perm()&0077 != 0 || !ok || stat.Uid != uint32(os.Getuid()) ||
		stat.Nlink != 1 || !os.SameFile(opened, named) {
		return errors.New("client attachment lease must be a stable private file")
	}
	return nil
}

func (r *Repository) liveClientAttachmentIDs() (map[string]bool, error) {
	live := map[string]bool{}
	if r.clientRoot == "" {
		return live, nil
	}
	directory := filepath.Join(r.clientRoot, "client-attachment-leases")
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".refs.json") {
			continue
		}
		id := strings.TrimSuffix(entry.Name(), ".refs.json")
		active, err := r.clientLeaseActive(id)
		if err != nil {
			return nil, err
		}
		if !active {
			continue
		}
		file, err := os.OpenFile(filepath.Join(directory, entry.Name()), os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
		if err != nil {
			return nil, err
		}
		data, err := readClientDraft(file)
		closeErr := file.Close()
		if err != nil || closeErr != nil {
			return nil, errors.Join(err, closeErr)
		}
		var refs struct {
			Version       int      `json:"version"`
			AttachmentIDs []string `json:"attachmentIDs"`
		}
		if err = model.Unmarshal(data, &refs); err != nil || refs.Version != 1 || refs.AttachmentIDs == nil {
			return nil, errors.New("live client attachment references are unreadable; collection stopped")
		}
		for _, reference := range refs.AttachmentIDs {
			if !managedID.MatchString(reference) {
				return nil, errors.New("live client contains an invalid attachment reference; collection stopped")
			}
			live[reference] = true
		}
	}
	return live, nil
}

func (r *Repository) draftAttachmentIDs() (map[string]bool, error) {
	live := map[string]bool{}
	if r.clientRoot == "" {
		return live, nil
	}
	if err := r.commandAttachmentIDs(live); err != nil {
		return nil, err
	}
	directory := filepath.Join(r.clientRoot, "client-drafts")
	if err := privateClientDirectory(directory); errors.Is(err, os.ErrNotExist) {
		return live, nil
	} else if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		file, err := os.OpenFile(filepath.Join(directory, entry.Name()), os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
		if err != nil {
			return nil, fmt.Errorf("read attachment draft ownership: %w", err)
		}
		data, err := readClientDraft(file)
		closeErr := file.Close()
		if err != nil || closeErr != nil {
			return nil, errors.Join(err, closeErr)
		}
		var draft clientDraft
		if err = model.Unmarshal(data, &draft); err != nil || draft.Version != 2 || draft.AttachmentIDs == nil ||
			len(draft.AttachmentIDs) > MaxMessageCount || len(draft.Scope) == 0 || len(draft.Value) == 0 {
			return nil, errors.New("client draft ownership is unreadable; attachment collection stopped")
		}
		for _, id := range draft.AttachmentIDs {
			if !managedID.MatchString(id) {
				return nil, errors.New("client draft contains an invalid attachment owner; collection stopped")
			}
			live[id] = true
		}
	}
	return live, nil
}

// An uncertain command may still be waiting for admission before RetainInput.
// Its existing durable receipt journal owns those files until the client has
// consumed or explicitly reconciled that outcome, including across a crash.
func (r *Repository) commandAttachmentIDs(live map[string]bool) error {
	file, err := os.OpenFile(filepath.Join(r.clientRoot, "client-command-journal.json"), os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	data, err := readClientDraft(file)
	closeErr := file.Close()
	if err != nil || closeErr != nil {
		return errors.Join(err, closeErr)
	}
	var journal struct {
		Version int    `json:"version"`
		HostID  string `json:"hostID"`
		Records []struct {
			Key           string   `json:"key"`
			ID            string   `json:"id"`
			Fingerprint   string   `json:"fingerprint"`
			Channel       string   `json:"channel"`
			Status        string   `json:"status"`
			AttachmentIDs []string `json:"attachmentIDs"`
		} `json:"records"`
	}
	if err = model.Unmarshal(data, &journal); err != nil || journal.Version != 1 || journal.HostID != "local" || journal.Records == nil || len(journal.Records) > 128 {
		return errors.New("client command ownership is unreadable; attachment collection stopped")
	}
	for _, record := range journal.Records {
		if record.ID == "" || record.Channel == "" || record.AttachmentIDs == nil || len(record.AttachmentIDs) > MaxMessageCount {
			return errors.New("client command attachment ownership is incomplete; collection stopped")
		}
		for _, id := range record.AttachmentIDs {
			if !managedID.MatchString(id) {
				return errors.New("client command contains an invalid attachment owner; collection stopped")
			}
			live[id] = true
		}
	}
	return nil
}

func readClientDraft(file *os.File) ([]byte, error) {
	const maximum = 144 * 1024 * 1024
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > maximum {
		return nil, errors.New("client draft is not a bounded regular file; collection stopped")
	}
	data, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if len(data) > maximum {
		return nil, errors.New("client draft exceeds its storage limit; collection stopped")
	}
	return data, err
}

func privateClientDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 || !ok || stat.Uid != uint32(os.Getuid()) {
		return errors.New("client attachment ownership directory must be private and owned by this account")
	}
	return nil
}

func (r *Repository) clientLeaseActive(id string) (bool, error) {
	return r.clientLease(id, false)
}

func (r *Repository) collectClientLeases() error {
	if r.clientRoot == "" {
		return nil
	}
	directory := filepath.Join(r.clientRoot, "client-attachment-leases")
	if err := privateClientDirectory(directory); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.Name() == "ownership.lock" {
			continue
		}
		var id string
		switch {
		case strings.HasSuffix(entry.Name(), ".lock"):
			id = strings.TrimSuffix(entry.Name(), ".lock")
		case strings.HasSuffix(entry.Name(), ".refs.json"):
			id = strings.TrimSuffix(entry.Name(), ".refs.json")
		default:
			continue
		}
		active, e := r.clientLease(id, true)
		if e != nil {
			return e
		}
		if active {
			continue
		}
		if err = os.Remove(filepath.Join(directory, id+".refs.json")); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

func (r *Repository) clientLease(id string, removeRetired bool) (bool, error) {
	if !model.ValidClientAttachmentLease(id) || r.clientRoot == "" {
		return false, errors.New("invalid client attachment lease")
	}
	directory := filepath.Join(r.clientRoot, "client-attachment-leases")
	if err := privateClientDirectory(directory); errors.Is(err, os.ErrNotExist) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	path := filepath.Join(directory, id+".lock")
	file, err := os.OpenFile(path, os.O_RDWR|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer file.Close()
	if err = validClientLock(file, path); err != nil {
		return false, err
	}
	if err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return true, nil
		}
		return false, err
	}
	defer syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	if removeRetired {
		// Holding the lock proves this process owner has ended. Creation checks
		// the named inode after locking, so an importer cannot use an unlinked
		// file if collection wins the create-to-flock race.
		if err = os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return false, err
		}
	}
	return false, nil
}

package profile

/*
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

static int open_client_lease(int directory, const char *name) {
    return openat(directory, name,
        O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
}

static int stat_client_lease(int directory, const char *name, struct stat *metadata) {
    return fstatat(directory, name, metadata, AT_SYMLINK_NOFOLLOW);
}
*/
import "C"

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// WithClientMaintenance excludes native startup and retained profile writers
// through the entire operation, including directory removal and rename. Native
// clients use the same admission lock before taking their lifetime shared lock.
// The operation receives canonical profiles in the requested order; repeated
// identities share one exclusive lease. No profile directories are created.
func WithClientMaintenance(directories []string, operation func([]Profile) error) (err error) {
	directory, err := openClientLeaseDirectory()
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, directory.Close()) }()
	var locks []*os.File
	defer func() {
		for i := len(locks) - 1; i >= 0; i-- {
			err = errors.Join(err, syscall.Flock(int(locks[i].Fd()), syscall.LOCK_UN), locks[i].Close())
		}
	}()
	admission, err := lockClientLease(directory, clientAdmissionFile, ErrClientAdmissionBusy)
	if err != nil {
		return err
	}
	locks = append(locks, admission)
	if err = verifyClientLeaseDirectory(directory); err != nil {
		return err
	}
	profiles := make([]Profile, len(directories))
	seen := make(map[string]bool, len(directories))
	for i, selected := range directories {
		p, err := Resolve(Options{DataDir: selected})
		if err != nil {
			return err
		}
		profiles[i] = p
		if seen[p.DataDir] {
			continue
		}
		lock, err := lockClientLease(directory, clientLeaseName(p.DataDir), ErrClientLeaseBusy)
		if err != nil {
			return fmt.Errorf("%w: %s", err, p.DataDir)
		}
		seen[p.DataDir] = true
		locks = append(locks, lock)
	}
	if err = verifyClientLeaseDirectory(directory); err != nil {
		return err
	}
	return operation(profiles)
}

func clientLeaseRoot() (string, error) {
	length, cause := C.confstr(C._CS_DARWIN_USER_TEMP_DIR, nil, 0)
	if length == 0 {
		return "", clientLeaseIO("locate the account temporary directory", cause)
	}
	if length > 16*1024 {
		return "", unsafeClientLease()
	}
	buffer := make([]byte, int(length))
	actual, cause := C.confstr(C._CS_DARWIN_USER_TEMP_DIR, (*C.char)(unsafe.Pointer(&buffer[0])), length)
	if actual == 0 {
		return "", clientLeaseIO("read the account temporary directory", cause)
	}
	if actual != length || bytes.IndexByte(buffer, 0) != len(buffer)-1 {
		return "", unsafeClientLease()
	}
	path := string(buffer[:len(buffer)-1])
	if !filepath.IsAbs(path) {
		return "", unsafeClientLease()
	}
	// HOME, TMPDIR and CFFIXED_USER_HOME must not split lease ownership for
	// processes using the same UID. The system-selected parent already exists.
	canonical, err := existingPath(path)
	if err != nil {
		return "", clientLeaseIO("resolve the account temporary directory", err)
	}
	return filepath.Join(canonical, clientLeaseDirectory), nil
}

func openClientLeaseDirectory() (*os.File, error) {
	path, err := clientLeaseRoot()
	if err != nil {
		return nil, err
	}
	if err = os.Mkdir(path, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return nil, clientLeaseIO("create the profile lease directory", err)
	}
	var before syscall.Stat_t
	if err = syscall.Lstat(path, &before); err != nil {
		return nil, clientLeaseIO("inspect the profile lease directory", err)
	}
	if !privateClientLeaseDirectory(&before) {
		return nil, unsafeClientLease()
	}
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, clientLeaseIO("open the profile lease directory", err)
	}
	directory := os.NewFile(uintptr(fd), path)
	var after syscall.Stat_t
	if err = syscall.Fstat(fd, &after); err != nil {
		return nil, errors.Join(clientLeaseIO("verify the profile lease directory", err), directory.Close())
	}
	if !privateClientLeaseDirectory(&after) || before.Dev != after.Dev || before.Ino != after.Ino {
		return nil, errors.Join(unsafeClientLease(), directory.Close())
	}
	return directory, nil
}

func verifyClientLeaseDirectory(directory *os.File) error {
	var opened, named syscall.Stat_t
	if err := syscall.Fstat(int(directory.Fd()), &opened); err != nil {
		return clientLeaseIO("verify the acquired profile lease directory", err)
	}
	if err := syscall.Lstat(directory.Name(), &named); err != nil {
		if errors.Is(err, syscall.ENOENT) {
			return unsafeClientLease()
		}
		return clientLeaseIO("verify the named profile lease directory", err)
	}
	if !privateClientLeaseDirectory(&opened) || !privateClientLeaseDirectory(&named) || opened.Dev != named.Dev || opened.Ino != named.Ino {
		return unsafeClientLease()
	}
	return nil
}

func privateClientLeaseDirectory(metadata *syscall.Stat_t) bool {
	return metadata.Mode&syscall.S_IFMT == syscall.S_IFDIR && metadata.Uid == uint32(os.Getuid()) && metadata.Mode&07777 == 0700
}

func lockClientLease(directory *os.File, name string, busy error) (_ *os.File, err error) {
	input := C.CString(name)
	defer C.free(unsafe.Pointer(input))
	var before C.struct_stat
	existed := false
	if result, cause := C.stat_client_lease(C.int(directory.Fd()), input, &before); result != 0 {
		if !errors.Is(cause, syscall.ENOENT) {
			return nil, clientLeaseIO("inspect the named profile lease file", cause)
		}
	} else {
		if !privateClientLease(&before) {
			return nil, unsafeClientLease()
		}
		existed = true
	}
	fd, cause := C.open_client_lease(C.int(directory.Fd()), input)
	if fd < 0 {
		if errors.Is(cause, syscall.ELOOP) {
			return nil, unsafeClientLease()
		}
		return nil, clientLeaseIO("open the profile lease file", cause)
	}
	file := os.NewFile(uintptr(fd), filepath.Join(directory.Name(), name))
	transferred := false
	defer func() {
		if !transferred {
			err = errors.Join(err, file.Close())
		}
	}()
	var metadata C.struct_stat
	if result, cause := C.fstat(fd, &metadata); result != 0 {
		return nil, clientLeaseIO("inspect the profile lease file", cause)
	}
	if !privateClientLease(&metadata) || (existed && (before.st_dev != metadata.st_dev || before.st_ino != metadata.st_ino)) {
		return nil, unsafeClientLease()
	}
	if err := syscall.Flock(int(fd), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return nil, busy
		}
		return nil, clientLeaseIO("acquire the profile lease", err)
	}
	if result, cause := C.fstat(fd, &metadata); result != 0 {
		return nil, clientLeaseIO("verify the acquired profile lease", cause)
	}
	var named C.struct_stat
	if result, cause := C.stat_client_lease(C.int(directory.Fd()), input, &named); result != 0 {
		if errors.Is(cause, syscall.ENOENT) {
			return nil, unsafeClientLease()
		}
		return nil, clientLeaseIO("verify the named profile lease file", cause)
	}
	if !privateClientLease(&metadata) || !privateClientLease(&named) || metadata.st_dev != named.st_dev || metadata.st_ino != named.st_ino {
		return nil, unsafeClientLease()
	}
	// These files are never removed or replaced. Kernel flock ownership follows
	// the open descriptor, independently of the profile path being rotated.
	transferred = true
	return file, nil
}

func privateClientLease(metadata *C.struct_stat) bool {
	return metadata.st_mode&C.S_IFMT == C.S_IFREG && metadata.st_uid == C.uid_t(os.Getuid()) && metadata.st_mode&0077 == 0 && metadata.st_nlink == 1
}

func unsafeClientLease() error {
	return model.NewError("UNSAFE_PROFILE_LOCK", "Profile lease metadata must be private, owned by the current account, and contain no symbolic or hard links")
}

func clientLeaseIO(operation string, cause error) error {
	if cause == nil {
		cause = syscall.EIO
	}
	return model.NewError("PROFILE_LOCK_IO", fmt.Sprintf("Unable to %s: %v", operation, cause))
}

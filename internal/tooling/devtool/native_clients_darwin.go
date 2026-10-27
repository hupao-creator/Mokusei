package devtool

/*
#cgo LDFLAGS: -lproc
#include <libproc.h>
#include <sys/sysctl.h>

static int native_arg_capacity(int *capacity) {
    int mib[] = {CTL_KERN, KERN_ARGMAX};
    size_t size = sizeof(*capacity);
    return sysctl(mib, 2, capacity, &size, NULL, 0);
}

static int native_process_args(int pid, char *buffer, size_t *size) {
    int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};
    return sysctl(mib, 3, buffer, size, NULL, 0);
}
*/
import "C"

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

func nativeClientProcesses(ctx context.Context) ([]nativeClientProcess, error) {
	// ps supplies numeric identities and the kernel's short executable name,
	// never a command/argument string. Only native candidates need a full path
	// lookup: unrelated programs may retain an unlinked executable image.
	output, err := run(ctx, "", nil, "/bin/ps", "-axo", "pid=,uid=,ucomm=")
	if err != nil {
		return nil, err
	}
	account, err := user.LookupId(strconv.Itoa(os.Getuid()))
	if err != nil {
		return nil, err
	}
	var clients []nativeClientProcess
	for _, line := range strings.Split(output, "\n") {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		if len(fields) < 3 {
			return nil, errors.New("invalid process identity snapshot")
		}
		if fields[1] != strconv.Itoa(os.Getuid()) || strings.Join(fields[2:], " ") != "Mokusei" {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil || pid <= 0 {
			return nil, errors.New("invalid native process identity")
		}
		path := make([]byte, C.PROC_PIDPATHINFO_MAXSIZE)
		n, cause := C.proc_pidpath(C.int(pid), unsafe.Pointer(&path[0]), C.uint32_t(len(path)))
		if n <= 0 {
			if errors.Is(cause, syscall.ESRCH) || errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) {
				continue
			}
			if cause == nil {
				cause = syscall.EIO
			}
			return nil, fmt.Errorf("cannot inspect native process %d executable: %w", pid, cause)
		}
		end := bytes.IndexByte(path, 0)
		if end < 0 {
			return nil, errors.New("unterminated native executable path")
		}
		executable := string(path[:end])
		if filepath.Base(executable) != "Mokusei" {
			continue
		}
		arguments, home, err := nativeProcessArguments(pid)
		if errors.Is(err, syscall.ESRCH) || (err != nil && errors.Is(syscall.Kill(pid, 0), syscall.ESRCH)) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("cannot inspect native client %d arguments: %w", pid, err)
		}
		if home == "" {
			// Foundation's current-user home uses the account directory, not
			// a shell HOME override. The Swift replay verifies this distinction.
			home = account.HomeDir
		}
		clients = append(clients, nativeClientProcess{pid: pid, executable: executable, arguments: arguments, home: home})
	}
	return clients, nil
}

func nativeProcessArguments(pid int) ([]string, string, error) {
	var capacity C.int
	if result, err := C.native_arg_capacity(&capacity); result != 0 {
		return nil, "", err
	}
	if capacity < 4 || capacity > 16*1024*1024 {
		return nil, "", errors.New("invalid native process argument capacity")
	}
	buffer := make([]byte, int(capacity))
	defer clear(buffer)
	size := C.size_t(len(buffer))
	if result, err := C.native_process_args(C.int(pid), (*C.char)(unsafe.Pointer(&buffer[0])), &size); result != 0 {
		return nil, "", err
	}
	if size < 4 || size > C.size_t(len(buffer)) {
		return nil, "", errors.New("invalid native process argument size")
	}
	count := int(binary.NativeEndian.Uint32(buffer[:4]))
	data := buffer[4:int(size)]
	end := bytes.IndexByte(data, 0)
	if count <= 0 || count > len(data) || end < 0 {
		return nil, "", errors.New("invalid native argument header")
	}
	data = bytes.TrimLeft(data[end:], "\x00") // kernel executable path and padding
	arguments := make([]string, 0, count)
	for range count {
		end := bytes.IndexByte(data, 0)
		if end < 0 {
			return nil, "", errors.New("truncated native arguments")
		}
		arguments = append(arguments, string(data[:end]))
		data = data[end+1:]
	}
	// Foundation honors its fixed-home override before the account directory.
	// Do not retain or report other environment values (including shell HOME).
	fixedHome := []byte("CFFIXED_USER_HOME=")
	for len(data) > 0 {
		end := bytes.IndexByte(data, 0)
		if end <= 0 {
			break
		}
		if bytes.HasPrefix(data[:end], fixedHome) {
			return arguments, string(data[len(fixedHome):end]), nil
		}
		data = data[end+1:]
	}
	return arguments, "", nil
}

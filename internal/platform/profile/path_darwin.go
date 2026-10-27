package profile

/*
#include <stdlib.h>
*/
import "C"

import (
	"os"
	"strings"
	"syscall"
	"unsafe"
)

// Darwin realpath returns the on-disk spelling on case-insensitive volumes,
// matching the Swift client's profile identity without folding sensitive paths.
func existingPath(path string) (string, error) {
	if strings.IndexByte(path, 0) >= 0 {
		return "", &os.PathError{Op: "realpath", Path: path, Err: syscall.EINVAL}
	}
	input := C.CString(path)
	defer C.free(unsafe.Pointer(input))
	resolved, err := C.realpath(input, nil)
	if resolved == nil {
		return "", &os.PathError{Op: "realpath", Path: path, Err: err}
	}
	defer C.free(unsafe.Pointer(resolved))
	return C.GoString(resolved), nil
}

//go:build windows

package profile

import (
	"github.com/hupao-creator/Chief/internal/core/model"
	"os"
)

func ownedByCurrentUser(os.FileInfo) bool { return false }
func verifyPrivatePlatform(string, bool) error {
	return model.NewError("UNSUPPORTED_PLATFORM", "Chief runtime currently supports Unix profile ownership; Windows ACL protection is not implemented")
}
func openPrivateFile(path string) (*os.File, error) { return nil, verifyPrivatePlatform(path, false) }
func IsProcessAlive(int) bool                       { return true }

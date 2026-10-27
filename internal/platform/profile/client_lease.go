package profile

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"path/filepath"
)

var ErrClientAdmissionBusy = errors.New("native profile startup or maintenance is in progress")
var ErrClientLeaseBusy = errors.New("a native client holds the profile lease")

const clientLeaseDirectory = "mokusei-profile-leases-v1"
const clientAdmissionFile = "admission.lock"

func clientLeaseName(dataDir string) string {
	digest := sha256.Sum256([]byte(dataDir))
	return hex.EncodeToString(digest[:]) + ".lock"
}

// ClientLeasePath identifies the permanent lease file for the profile's current
// canonical directory. It creates nothing and confers no ownership; callers
// acquire authority through WithClientMaintenance or native client admission.
func ClientLeasePath(p Profile) (string, error) {
	p, err := Refresh(p)
	if err != nil {
		return "", err
	}
	root, err := clientLeaseRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, clientLeaseName(p.DataDir)), nil
}

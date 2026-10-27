//go:build !darwin

package profile

import "github.com/hupao-creator/Mokusei/internal/core/model"

func WithClientMaintenance([]string, func([]Profile) error) error {
	return model.NewError("UNSUPPORTED_PLATFORM", "Native profile client leases require macOS")
}

func clientLeaseRoot() (string, error) {
	return "", model.NewError("UNSUPPORTED_PLATFORM", "Native profile client leases require macOS")
}

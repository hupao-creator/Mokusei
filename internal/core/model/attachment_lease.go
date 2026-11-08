package model

import (
	"context"
	"regexp"
)

type clientAttachmentLeaseKey struct{}

var clientAttachmentLeasePattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

func ValidClientAttachmentLease(id string) bool { return clientAttachmentLeasePattern.MatchString(id) }

// The authenticated local transport carries the client's process lease through
// accepted commands. Socket cancellation does not end that filesystem owner.
func WithClientAttachmentLease(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, clientAttachmentLeaseKey{}, id)
}

func ClientAttachmentLease(ctx context.Context) string {
	id, _ := ctx.Value(clientAttachmentLeaseKey{}).(string)
	return id
}

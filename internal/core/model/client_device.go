package model

import "context"

type clientDeviceKey struct{}

// WithClientDevice is called only by authenticated host transport, never from
// command JSON. Local calls and native host clients have the stable host owner.
func WithClientDevice(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, clientDeviceKey{}, id)
}

func ClientDeviceID(ctx context.Context) string {
	if id, ok := ctx.Value(clientDeviceKey{}).(string); ok && id != "" {
		return id
	}
	return "host"
}

//go:build race

package opencode

// Race instrumentation slows the large-state decode by more than an order of
// magnitude; the allocation bound remains the primary regression assertion.
const detailRaceEnabled = true

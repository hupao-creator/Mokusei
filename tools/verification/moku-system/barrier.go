package main

import (
	"strings"
	"sync"
	"time"
)

type responseBarrier struct {
	entered, release, finished         chan struct{}
	enterOnce, releaseOnce, finishOnce sync.Once
}

func (p *provider) armBarrier(marker string) *responseBarrier {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.barriers == nil {
		p.barriers = map[string]*responseBarrier{}
	}
	gate := &responseBarrier{entered: make(chan struct{}), release: make(chan struct{}), finished: make(chan struct{})}
	p.barriers[marker] = gate
	return gate
}
func (g *responseBarrier) unblock() { g.releaseOnce.Do(func() { close(g.release) }) }
func (p *provider) waitBarrier(input any) func() {
	latest := ""
	for _, v := range list(input) {
		m := record(v)
		if m["role"] == "user" {
			latest = string(encoded(m["content"]))
		}
	}
	p.mu.Lock()
	var gate *responseBarrier
	for marker, g := range p.barriers {
		if strings.Contains(latest, marker) {
			gate = g
			break
		}
	}
	p.mu.Unlock()
	if gate == nil {
		return func() {}
	}
	gate.enterOnce.Do(func() { close(gate.entered) })
	// Keep the synthetic late response pending even after the native HTTP request
	// is cancelled. The action releases it only after public interruption settles.
	timer := time.NewTimer(30 * time.Second)
	defer timer.Stop()
	select {
	case <-gate.release:
	case <-timer.C:
		p.mu.Lock()
		p.failures = append(p.failures, "response barrier not released")
		p.mu.Unlock()
	}
	return func() { gate.finishOnce.Do(func() { close(gate.finished) }) }
}

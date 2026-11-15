package sessioncache

import (
	"context"
	"testing"
)

func TestRetiredHandleDoesNotDeleteReplacement(t *testing.T) {
	for _, retirement := range []string{"evict-thread", "projection-budget"} {
		t.Run(retirement, func(t *testing.T) {
			c := NewCache(1 << 20)
			build := func(context.Context, any, *Projections) (any, int64, error) { return "value", 100, nil }
			old, err := c.Acquire(context.Background(), "thread", "old", 1, build)
			if err != nil {
				t.Fatal(err)
			}
			if retirement == "evict-thread" {
				c.ReleaseThread("thread")
			} else {
				old.AddSize(1 << 20)
			}
			current, err := c.Acquire(context.Background(), "thread", "new", 2, build)
			if err != nil {
				t.Fatal(err)
			}
			// The old reader drains only after the replacement has been installed.
			done := make(chan struct{})
			go func() { old.Release(); close(done) }()
			<-done
			if c.threads["thread"] != current.Entry {
				t.Fatalf("retired handle removed replacement; stats=%+v", c.Stats())
			}
			current.Release()
			stats := c.Stats()
			if stats.Threads != 1 || stats.Bytes != 100+entryOverhead {
				t.Fatalf("replacement accounting: %+v", stats)
			}
			c.ReleaseThread("thread")
			if stats := c.Stats(); stats.Threads != 0 || stats.Bytes != 0 {
				t.Fatalf("unreleased accounting: %+v", stats)
			}
		})
	}
}

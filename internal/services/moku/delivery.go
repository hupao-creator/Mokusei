package moku

import (
	"context"
	"encoding/json"
	"time"

	"github.com/hupao-creator/Chief/internal/core/plugin"
)

// Delivery retries only work that has not reached native Send. The runtime owns
// the durable attempt fence and admission receipt; callbacks are wake hints.
func (c *Coordinator) deliveryLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		c.drainDeliveries(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
func (c *Coordinator) drainDeliveries(ctx context.Context) {
	deliveries, err := c.config.PendingDeliveries()
	if err != nil {
		return
	}
	for _, delivery := range deliveries {
		if ctx.Err() != nil {
			return
		}
		if delivery.Uncertain {
			continue
		}
		if delivery.Lazy {
			current, err := c.current()
			if err != nil || current.Observation.LatestExecution == nil || current.Observation.LatestExecution.Terminal() {
				continue
			}
			harness := c.config.Harnesses[current.HarnessID]
			if harness == nil || !harness.Descriptor().ThreadCapabilities.FollowUpOnly {
				continue
			}
		}
		if err := c.queue.Lock(ctx); err != nil {
			return
		}
		_ = c.admitSettings(ctx, func(ctx context.Context) error { return c.deliverNotification(ctx, delivery) })
		c.queue.Unlock()
	}
}
func (c *Coordinator) deliverNotification(ctx context.Context, delivery plugin.MokuDelivery) error {
	return retryConfigurationAdmission(func() error {
		record, err := c.ensure(ctx)
		if err != nil {
			return err
		}
		thread := publicThread(delivery.Thread)
		if delivery.UserAction != nil {
			thread["event"] = delivery.UserAction
		}
		serialized, err := json.Marshal(thread)
		if err != nil {
			return err
		}
		input := textInput("Mokusei Agent Thread terminal event:\n" + string(serialized))
		if delivery.Notification != "" {
			input = textInput(delivery.Notification)
		}
		input.Presentation = "internal"
		entries, err := c.sendContext(ctx, input, nil, nil)
		if err != nil {
			return err
		}
		c.mu.Lock()
		injection := c.injection
		c.mu.Unlock()
		_, err = c.config.SendDelivery(ctx, delivery.ID, record.ID, input, injection, entries)
		return err
	})
}

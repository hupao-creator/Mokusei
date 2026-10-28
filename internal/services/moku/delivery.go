package moku

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// Delivery retries only work that has not reached native Send. The runtime owns
// the durable attempt fence and admission receipt; callbacks are wake hints.
func (c *Coordinator) deliveryLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	reported := map[string]string{}
	for {
		c.drainDeliveries(ctx, reported)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
func (c *Coordinator) drainDeliveries(ctx context.Context, reported map[string]string) {
	deliveries, err := c.config.PendingDeliveries()
	if err != nil {
		c.report("moku-delivery-read", err)
		return
	}
	present := map[string]bool{}
	for _, delivery := range deliveries {
		present[delivery.ID] = true
		if ctx.Err() != nil {
			return
		}
		if delivery.Uncertain {
			message := "native admission uncertain; automatic replay withheld; inspect moku:deliveries and native conversation, then use moku:resolve-delivery with confirmed decision for " + delivery.ID
			if reported[delivery.ID] != message {
				c.report("moku-delivery-uncertain", fmt.Errorf("%s", message))
				reported[delivery.ID] = message
			}
			continue
		}
		if err := c.queue.Lock(ctx); err != nil {
			return
		}
		err = c.admitSettings(ctx, func(ctx context.Context) error { return c.deliverTerminal(ctx, delivery) })
		c.queue.Unlock()
		if err != nil && ctx.Err() == nil {
			if reported[delivery.ID] != err.Error() {
				c.report("moku-delivery", err)
				reported[delivery.ID] = err.Error()
			}
		}
	}
	for id := range reported {
		if !present[id] {
			delete(reported, id)
		}
	}
}
func (c *Coordinator) deliverTerminal(ctx context.Context, delivery plugin.MokuDelivery) error {
	record, err := c.ensure(ctx)
	if err != nil {
		return err
	}
	serialized, err := json.Marshal(publicThread(delivery.Thread))
	if err != nil {
		return err
	}
	input := textInput("Mokusei Agent Thread terminal event:\n" + string(serialized))
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
}

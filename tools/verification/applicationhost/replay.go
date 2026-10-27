package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/report"
)

func (h *harness) replay(ctx context.Context) (string, error) {
	if err := verifyCollectionList(ctx); err != nil {
		return "", err
	}
	h.checks = append(h.checks, "collection listing preserves durable order, sorted unlisted records and missing-record omission")
	work, err := h.beginBatch(ctx, "applicationhost-replay-event-1")
	if err != nil {
		return "", err
	}
	options := writeOptions(h.consumer.ID(), work, "create-report")
	_, err = h.host.Command(ctx, plugin.OperationRequest{PluginID: "report", OperationID: "report.create", RequestID: "untrusted-ui", Input: createInput()})
	if err = expectFailure(err, "UI cannot invoke background-only report.create"); err != nil {
		return "", err
	}
	_, err = h.domain.Execute(ctx, "report.create", createInput(), plugin.DomainCommandOptions{RequestID: "missing-batch"})
	if err = expectFailure(err, "background report write requires a batch"); err != nil {
		return "", err
	}
	input, err := model.DecodeObject(createInput())
	if err != nil {
		return "", err
	}
	input["source"] = "application"
	input["owner"] = "report.agent"
	_, err = h.domain.Execute(ctx, "report.create", encode(input), options)
	if err = expectFailure(err, "input cannot supply trusted source or owner headers"); err != nil {
		return "", err
	}
	input, err = model.DecodeObject(createInput())
	if err != nil {
		return "", err
	}
	input["scope"] = "/foreign/scope"
	_, err = h.domain.Execute(ctx, "report.create", encode(input), options)
	if err = expectFailure(err, "domain rejects model-supplied scope"); err != nil {
		return "", err
	}
	h.checks = append(h.checks, "user/background audiences and batch requirement", "source/owner fields rejected by the actual closed Report input contract")
	h.tamperScope.Store(true)
	_, err = h.domain.Execute(ctx, "report.create", createInput(), options)
	h.tamperScope.Store(false)
	if err = expectFailure(err, "planner cannot forge a host scope token"); err != nil {
		return "", err
	}
	catalog, err := h.host.Catalog(ctx)
	if err != nil {
		return "", err
	}
	if len(catalog) != 0 {
		return "", errors.New("rejected command published a Report")
	}
	h.checks = append(h.checks, "forged snapshot scope rejected without partial record writes")
	summary, created, err := h.create(ctx, options)
	if err != nil {
		return "", err
	}
	replayed, err := h.domain.Execute(ctx, "report.create", createInput(), options)
	if err != nil {
		return "", err
	}
	if string(replayed) != string(created) {
		return "", errors.New("same request did not replay the exact outcome")
	}
	alias := options
	alias.RequestID = "request-alias"
	replayed, err = h.domain.Execute(ctx, "report.create", createInput(), alias)
	if err != nil {
		return "", err
	}
	if string(replayed) != string(created) {
		return "", errors.New("same batch invocation did not replay the exact outcome")
	}
	input, err = model.DecodeObject(createInput())
	if err != nil {
		return "", err
	}
	input["title"] = "Conflicting request payload"
	_, err = h.domain.Execute(ctx, "report.create", encode(input), options)
	if err = expectFailure(err, "same request identity cannot change parameters"); err != nil {
		return "", err
	}
	h.checks = append(h.checks, "command receipt and batch invocation replay", "reused identity with a different payload rejected")
	catalog, err = h.host.Catalog(ctx)
	if err != nil {
		return "", err
	}
	if len(catalog) != 1 || catalog[0].Title != fixtureTitle || catalog[0].Revision != 1 {
		return "", errors.New("Report create did not publish the expected catalog")
	}
	var view map[string]json.RawMessage
	if err = json.Unmarshal(catalog[0].View, &view); err != nil {
		return "", err
	}
	if _, exists := view["html"]; exists {
		return "", errors.New("catalog carries full Report HTML")
	}
	if err = h.checkQuery(ctx, summary.ID, fixtureHTML); err != nil {
		return "", err
	}
	h.checks = append(h.checks, "bounded Report catalog and complete report.html query")
	// Concurrent real reducers all read and commit at the same serialized store
	// boundary. Distinct invocations cannot overwrite each other's revisions.
	const updates = 8
	var wg sync.WaitGroup
	failures := make(chan error, updates)
	for index := range updates {
		wg.Add(1)
		go func(index int) {
			defer wg.Done()
			html := fmt.Sprintf("<html><body><p>Concurrent Report update %d.</p></body></html>", index)
			payload := encode(report.UpdateInput{ReportID: summary.ID, HTML: &html})
			_, err := h.domain.Execute(ctx, "report.update", payload, writeOptions(h.consumer.ID(), work, fmt.Sprintf("update-%d", index)))
			if err != nil {
				failures <- err
			}
		}(index)
	}
	wg.Wait()
	close(failures)
	for err := range failures {
		return "", err
	}
	catalog, err = h.host.Catalog(ctx)
	if err != nil {
		return "", err
	}
	if catalog[0].Revision != 1+updates {
		return "", errors.New("concurrent commands lost a record revision")
	}
	html := fixtureHTML
	_, err = h.domain.Execute(ctx, "report.update", encode(report.UpdateInput{ReportID: summary.ID, HTML: &html}), writeOptions(h.consumer.ID(), work, "restore-fixture"))
	if err != nil {
		return "", err
	}
	if err = h.checkQuery(ctx, summary.ID, fixtureHTML); err != nil {
		return "", err
	}
	h.checks = append(h.checks, "concurrent real Report updates preserve each committed revision")
	ref := model.ThreadRef{ThreadID: summary.ID, TypeID: report.ThreadTypeID}
	if err = h.host.Archive(ctx, ref, true); err != nil {
		return "", err
	}
	catalog, err = h.host.Catalog(ctx)
	if err != nil {
		return "", err
	}
	if !catalog[0].Archived {
		return "", errors.New("archive projection did not update")
	}
	h.checks = append(h.checks, "archive projection and entity/lifecycle facts")
	events, err := h.store.Snapshot().Events()
	if err != nil {
		return "", err
	}
	createdEvent := false
	for _, event := range events {
		if event.Subject.ID == summary.ID && event.Type == "entity.created" {
			createdEvent = true
			if event.Source != "report.agent.inbox" {
				return "", errors.New("Report entity event did not use the trusted caller identity")
			}
		}
	}
	if !createdEvent {
		return "", errors.New("Report create omitted its atomic entity event")
	}
	h.checks = append(h.checks, "entity source is derived from the trusted background owner")
	if err = h.consumer.Settle(ctx, work.ID, "processed"); err != nil {
		return "", err
	}
	_, err = h.domain.Execute(ctx, "report.create", createInput(), options)
	if err = expectFailure(err, "settled batch cannot replay a write"); err != nil {
		return "", err
	}
	next, err := h.beginBatch(ctx, "applicationhost-replay-event-2")
	if err != nil {
		return "", err
	}
	second, _, err := h.create(ctx, writeOptions(h.consumer.ID(), next, "create-report"))
	if err != nil {
		return "", err
	}
	if second.ID == summary.ID {
		return "", errors.New("distinct batches accidentally share command identity")
	}
	if err = h.consumer.Settle(ctx, next.ID, "processed"); err != nil {
		return "", err
	}
	h.checks = append(h.checks, "settled batch fence and separate identities for reused call IDs in new batches")
	_, err = h.store.Update(ctx, func(tx *store.Tx) error {
		return tx.AppendEvent(store.Event{ID: "untrusted-source-event", CreatedAt: fixtureAt, Type: "execution.completed", Subject: store.Subject{Kind: "thread", ID: "verification-task", TypeID: "agent"}, Source: "untrusted", Data: json.RawMessage(`{}`)})
	})
	if err != nil {
		return "", err
	}
	_, err = h.consumer.Begin(ctx, []string{"untrusted-source-event"})
	if err = expectFailure(err, "consumer filter excludes untrusted source"); err != nil {
		return "", err
	}
	h.checks = append(h.checks, "actual lifecycle consumer rejects events outside its source filter")
	if err = h.verifyDirectoryTags(ctx, summary.ID); err != nil {
		return "", err
	}
	return summary.ID, nil
}
func verifyReopen(ctx context.Context, data, id string) error {
	h, err := openHarness(ctx, data)
	if err != nil {
		return err
	}
	defer h.close()
	if err = h.checkQuery(ctx, id, fixtureHTML); err != nil {
		return err
	}
	catalog, err := h.host.Catalog(ctx)
	if err != nil {
		return err
	}
	if len(catalog) != 2 {
		return errors.New("SQLite reopen lost Report records")
	}
	found := false
	for _, entry := range catalog {
		if entry.ID == id {
			found = true
			if !entry.Archived {
				return errors.New("SQLite reopen lost archive state")
			}
			if len(entry.Tags.DirectoryTags) != 0 || len(entry.Tags.Tags) != 1 || len(entry.Tags.SemanticTags) != 1 || entry.Tags.SemanticTags[0] != "Keep" || entry.Tags.TagEmojis["Keep"] != "👩🏽‍💻" {
				return errors.New("SQLite startup did not remove stale temporary directory tags while preserving semantic tags")
			}
		}
	}
	if !found {
		return errors.New("SQLite reopen lost the original Report")
	}
	return h.close()
}

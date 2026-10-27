package main

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"reflect"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

func verifyCommittedRecords(ctx context.Context, directory string) {
	db, err := store.Open(filepath.Join(directory, "committed-records.sqlite"))
	must(err)
	defer db.Close()
	var fixture model.ThreadRecord
	must(json.Unmarshal([]byte(`{
		"harnessId":"fixture","revision":1,"createdAt":1,"updatedAt":1,
		"sessionState":{"messages":["opaque session"],"native":{"value":1}},
		"settings":{"native":{"value":2}},"settingsRevision":3,
		"worktree":{"cwd":"fixture-worktree"},
		"observation":{
			"backgroundWork":{"status":"running"},
			"latestExecution":{
				"executionId":"execution","status":"waiting-for-user","startedAt":1,
				"summary":"summary",
				"interactions":[{
					"id":"interaction","kind":"question","title":"title","description":"description",
					"actions":[{"id":"answer","intent":"submit","label":"Answer"}],
					"questions":[{
						"id":"question","prompt":"Prompt","header":"Header",
						"options":[{"value":"first","label":"First","description":"option"}],
						"form":{
							"type":"string","required":true,"hidden":false,"default":"first",
							"when":[{"questionId":"other","op":"eq","value":"yes"}],
							"optionValues":{"first":"value"},"minimum":1,"maximum":2,
							"minLength":1,"maxLength":2,"pattern":".*","minItems":1,"maxItems":2
						}
					}]
				}]
			}
		},
		"title":"original","metadataState":{"title":"metadata"},"metadataRevision":4,
		"tags":["original"],"tagEmojis":{"original":"🔬"},"archived":false,
		"note":{"id":"note","text":"note text","revision":1,"updatedAt":1},
		"transcript":[{"id":"first","content":"first"},{"id":"second","content":"second"}]
	}`), &fixture))
	must(model.ValidatePublicObservation(fixture.Observation))
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		for _, id := range []string{"unordered-z", "ordered-first", "unordered-a", "ordered-second"} {
			record := fixture
			record.ID = id
			if err := tx.Put("thread:"+id, record); err != nil {
				return err
			}
		}
		return tx.SetOrder("threads", []string{"ordered-second", "missing", "ordered-first"})
	})
	must(err)
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": harness{}}, DataDir: directory})
	must(err)
	defer r.Close(ctx)
	threads, err := r.Threads()
	must(err)
	ids := make([]string, len(threads))
	for index, thread := range threads {
		ids[index] = thread.ID
	}
	if !reflect.DeepEqual(ids, []string{"ordered-second", "ordered-first", "unordered-a", "unordered-z"}) {
		panic(fmt.Sprintf("thread enumeration changed explicit order or duplicated records: %v", ids))
	}

	calls := [2]int{}
	var failure string
	watch := func(index int) func() {
		return r.OnThreadCommitted(func(record model.ThreadRecord) {
			calls[index]++
			saved, readErr := r.Thread(record.ID)
			if readErr != nil || !reflect.DeepEqual(record, saved) {
				failure = fmt.Sprintf("subscriber %d received a changed or incomplete committed record: %v", index, readErr)
				return
			}
			// Every listener mutates its own delivery, so this works regardless of
			// the listener map's iteration order and catches sharing in either direction.
			record.SessionState[0] = 'x'
			record.Settings[0] = 'x'
			record.MetadataState[0] = 'x'
			record.Transcript[0][0] = 'x'
			record.Transcript[1] = json.RawMessage(`null`)
			record.Tags[0] = "changed"
			record.TagEmojis["original"] = "changed"
			record.Worktree.Cwd = "changed"
			record.Note.Text = "changed"
			*record.MetadataRevision = 99
			*record.Archived = true
			record.Observation.BackgroundWork.Status = "changed"
			execution := record.Observation.LatestExecution
			*execution.Summary = "changed"
			if execution.FinishedAt != nil {
				*execution.FinishedAt = 99
			}
			if execution.Error != nil {
				*execution.Error = "changed"
			}
			if len(execution.Interactions) == 0 {
				return
			}
			interaction := &execution.Interactions[0]
			interaction.Title = "changed"
			*interaction.Description = "changed"
			interaction.Actions[0].Label = "changed"
			question := &interaction.Questions[0]
			question.Prompt = "changed"
			*question.Header = "changed"
			question.Options[0].Label = "changed"
			*question.Options[0].Description = "changed"
			form := question.Form
			*form.Hidden = true
			form.Default[0] = 'x'
			form.When[0].Value[0] = 'x'
			form.OptionValues["first"] = "changed"
			*form.Minimum = 99
			*form.Maximum = 99
			*form.MinLength = 99
			*form.MaxLength = 99
			*form.Pattern = "changed"
			*form.MinItems = 99
			*form.MaxItems = 99
		})
	}
	unwatchFirst, unwatchSecond := watch(0), watch(1)
	defer unwatchFirst()
	defer unwatchSecond()
	var retained *model.ThreadRecord
	must(r.UpdateThread(ctx, "ordered-first", func(record *model.ThreadRecord) error {
		record.Title = "updated"
		retained = record
		return nil
	}))
	if failure != "" {
		panic(failure)
	}
	if calls != [2]int{1, 1} {
		panic(fmt.Sprintf("committed record listeners missed a delivery: %v", calls))
	}
	saved, err := r.Thread("ordered-first")
	must(err)
	if !reflect.DeepEqual(*retained, saved) {
		panic("subscriber mutated the update owner's committed record")
	}
	if saved.Title != "updated" || saved.Tags[0] != "original" || !json.Valid(saved.SessionState) {
		panic("subscriber mutated durable thread state")
	}
	must(r.UpdateThread(ctx, saved.ID, func(record *model.ThreadRecord) error {
		execution := record.Observation.LatestExecution
		execution.Status = "failed"
		execution.Interactions = nil
		finished, message := int64(2), "failure"
		execution.FinishedAt, execution.Error = &finished, &message
		retained = record
		return model.ValidatePublicObservation(record.Observation)
	}))
	saved, err = r.Thread(saved.ID)
	must(err)
	if failure != "" || calls != [2]int{2, 2} || !reflect.DeepEqual(*retained, saved) {
		panic(fmt.Sprintf("terminal committed record ownership failed: %s; calls %v", failure, calls))
	}
	unwatchFirst()
	unwatchFirst()
	unwatchSecond()
	must(r.UpdateThread(ctx, saved.ID, func(record *model.ThreadRecord) error { record.Title = "unsubscribed"; return nil }))
	if calls != [2]int{2, 2} {
		panic("released committed record listener received another delivery")
	}
	fmt.Println("PASS ordered thread enumeration and independently owned committed records, nested observations, opaque payloads and subscription release")
}

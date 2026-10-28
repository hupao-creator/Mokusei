package moku

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func (c *Coordinator) appendTranscript(ctx context.Context, threadID string, item map[string]any) error {
	return c.config.UpdateThread(ctx, threadID, func(record *model.ThreadRecord) error {
		if !record.Moku {
			return errors.New("Moku transcript owner was replaced")
		}
		created := time.Now().UnixMilli()
		if raw, ok := item["createdAt"].(int64); ok && raw > created {
			created = raw
		}
		if record.UpdatedAt > created {
			created = record.UpdatedAt
		}
		for _, raw := range record.Transcript {
			var existing map[string]any
			if json.Unmarshal(raw, &existing) != nil {
				return errors.New("invalid Moku transcript")
			}
			if existing["id"] == item["id"] {
				return errors.New("duplicate Moku transcript ID")
			}
			if item["type"] == "tool-operation" && existing["callId"] == item["callId"] {
				return errors.New("duplicate Moku tool call ID")
			}
			if timestamp, ok := existing["createdAt"].(float64); ok && int64(timestamp) > created {
				created = int64(timestamp)
			}
		}
		item["createdAt"] = created
		raw, err := json.Marshal(item)
		if err != nil {
			return err
		}
		record.Transcript = append(record.Transcript, raw)
		return nil
	})
}
func (c *Coordinator) completeTool(ctx context.Context, threadID, executionID, callID string, result json.RawMessage, isError bool) error {
	return c.config.UpdateThread(ctx, threadID, func(record *model.ThreadRecord) error {
		matches := 0
		for index, raw := range record.Transcript {
			var item map[string]any
			if json.Unmarshal(raw, &item) != nil {
				return errors.New("invalid Moku transcript")
			}
			if item["type"] != "tool-operation" || item["executionId"] != executionID || item["callId"] != callID {
				continue
			}
			if _, done := item["completedAt"]; done {
				return errors.New("Moku tool operation already completed")
			}
			matches++
			item["completedAt"] = max(time.Now().UnixMilli(), record.UpdatedAt)
			if item["name"] == "read_clipboard" {
				// Never persist clipboard text, including unexpected error payloads.
				// The original result still goes back to the calling model.
				audit := map[string]any{"redacted": true}
				if !isError {
					var metadata struct {
						OK         bool `json:"ok"`
						Empty      bool `json:"empty"`
						Truncated  bool `json:"truncated"`
						Characters int  `json:"characters"`
					}
					if err := json.Unmarshal(result, &metadata); err != nil {
						return errors.New("invalid clipboard result metadata")
					}
					audit["ok"], audit["empty"] = metadata.OK, metadata.Empty
					audit["truncated"], audit["characters"] = metadata.Truncated, metadata.Characters
				}
				item["result"] = audit
			} else {
				item["result"] = result
			}
			if isError {
				item["isError"] = true
			}
			encoded, err := json.Marshal(item)
			if err != nil {
				return err
			}
			record.Transcript[index] = encoded
		}
		if matches != 1 {
			return errors.New("Moku pending tool operation is missing or ambiguous")
		}
		return nil
	})
}
func (c *Coordinator) settleExecution(ctx context.Context, record model.ThreadRecord) error {
	execution := record.Observation.LatestExecution
	if execution == nil || !execution.Terminal() {
		return nil
	}
	return c.config.UpdateThread(ctx, record.ID, func(current *model.ThreadRecord) error {
		status := "complete"
		if execution.Status == "interrupted" {
			status = "cancelled"
		}
		if execution.Status == "failed" {
			status = "failed"
		}
		for index, raw := range current.Transcript {
			var item map[string]any
			if json.Unmarshal(raw, &item) != nil {
				return errors.New("invalid Moku transcript")
			}
			if item["executionId"] != execution.ExecutionID {
				continue
			}
			changed := false
			if item["type"] == "message" && item["role"] == "assistant" && item["status"] == "streaming" {
				item["status"] = status
				changed = true
			}
			if item["type"] == "tool-operation" {
				if _, done := item["completedAt"]; !done {
					item["completedAt"] = max(time.Now().UnixMilli(), current.UpdatedAt)
					audit := map[string]any{"error": "Moku execution terminated before tool completion"}
					if item["name"] == "read_clipboard" {
						audit["redacted"] = true
					}
					item["result"] = audit
					item["isError"] = true
					changed = true
				}
			}
			if changed {
				encoded, err := json.Marshal(item)
				if err != nil {
					return err
				}
				current.Transcript[index] = encoded
			}
		}
		return nil
	})
}
func userMessage(input model.AgentInput, id string, at int64) map[string]any {
	content := ""
	previous := ""
	attachments := []map[string]any{}
	for _, part := range input.Parts {
		switch part.Kind {
		case "text", "mention":
			if previous == "text" && part.Kind == "text" {
				content += "\n"
			}
			if previous == "mention" && part.Kind == "mention" {
				content += " "
			}
			if part.Kind == "text" {
				content += part.Text
			} else {
				path, _ := json.Marshal(part.Path)
				content += "@" + string(path)
			}
			previous = part.Kind
		case "local-file", "image", "audio":
			if part.File == nil {
				continue
			}
			kind := "file"
			if part.Kind == "image" {
				kind = "image"
			} else if part.File.MimeType == "application/pdf" || strings.HasPrefix(part.File.MimeType, "text/") {
				kind = "document"
			}
			attachments = append(attachments, map[string]any{"id": part.File.ID, "path": part.File.Path, "name": part.File.Name, "mimeType": part.File.MimeType, "size": part.File.Size, "kind": kind})
		}
	}
	item := map[string]any{"type": "message", "id": id, "role": "user", "content": content, "status": "complete", "createdAt": at}
	if len(attachments) > 0 {
		item["attachments"] = attachments
	}
	return item
}
func (c *Coordinator) committed(record model.ThreadRecord) {
	if record.MokuHistory {
		return
	}
	c.mu.Lock()
	if !c.running {
		c.mu.Unlock()
		return
	}
	// The durable outbox owns ordinary terminal notifications. Do not retain a
	// second copy of their full native history while the event queue is blocked.
	if !record.Moku && c.config.PendingDeliveries != nil && c.config.SendDelivery != nil {
		c.mu.Unlock()
		return
	}
	execution := record.Observation.LatestExecution
	if record.Moku && record.ID == c.id && execution != nil {
		for id, scope := range c.scopes {
			if id != execution.ExecutionID || execution.Terminal() {
				scope.cancel()
				delete(c.scopes, id)
			}
		}
		if !execution.Terminal() {
			if _, exists := c.scopes[execution.ExecutionID]; !exists {
				ctx, cancel := context.WithCancel(c.ctx)
				c.scopes[execution.ExecutionID] = executionScope{record.ID, ctx, cancel}
			}
		}
	}
	terminal := execution != nil && execution.Terminal()
	key := ""
	if terminal {
		key = execution.ExecutionID + ":" + execution.Status
	}
	if !terminal || c.observed[record.ID] == key {
		c.mu.Unlock()
		return
	}
	c.observed[record.ID] = key
	c.mu.Unlock()
	c.enqueueEvent(coordinatorEvent{record: &record})
}
func (c *Coordinator) enqueueEvent(event coordinatorEvent) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.running || (event.lifetime != nil && event.lifetime.Err() != nil) {
		return
	}
	c.events = append(c.events, event)
	select {
	case c.eventWake <- struct{}{}:
	default:
	}
}
func (c *Coordinator) eventsLoop(ctx context.Context) {
	for {
		c.mu.Lock()
		var event coordinatorEvent
		has := len(c.events) > 0
		if has {
			event = c.events[0]
			c.events[0] = coordinatorEvent{}
			c.events = c.events[1:]
		}
		c.mu.Unlock()
		if !has {
			select {
			case <-ctx.Done():
				return
			case <-c.eventWake:
			}
			continue
		}
		if event.record != nil && event.record.Moku {
			current, err := c.current()
			if err != nil || current.ID != event.record.ID {
				continue
			}
			c.report("moku-tool-settlement", c.settleExecution(context.WithoutCancel(ctx), *event.record))
			c.voice.deliver(*event.record)
			continue
		}

		if event.diagnostic != "" {
			current, err := c.current()
			if err == nil {
				err = c.appendTranscript(ctx, current.ID, map[string]any{"type": "message", "id": newID(), "role": "assistant", "content": event.diagnostic, "status": "complete", "systemEvent": true, "createdAt": time.Now().UnixMilli()})
			}
			if err != nil && ctx.Err() == nil {
				c.report("diagnostic-event", err)
			}
			continue
		}
		if err := c.queue.Lock(ctx); err != nil {
			// Local terminal settlement uses WithoutCancel and must still
			// drain even though this outbound notification can no longer enter.
			continue
		}
		err := c.admitSettings(ctx, func(ctx context.Context) error {
			return retryConfigurationAdmission(func() error {
				if err := ctx.Err(); err != nil {
					return err
				}
				subjectID := ""
				if event.record != nil {
					subjectID = event.record.ID
				} else if event.userInput != nil {
					subjectID = event.userInput.Subject.ID
				}
				if subjectID == "" {
					return nil
				}
				if c.config.IsDeleting != nil && c.config.IsDeleting(subjectID) {
					return nil
				}
				subject, existsErr := c.config.Thread(subjectID)
				if existsErr != nil || subject.Moku || subject.MokuHistory {
					return nil
				}
				record, err := c.ensure(ctx)
				if err != nil {
					return err
				}
				var input model.AgentInput
				if event.userInput != nil {
					input = userThreadInputNotification(*event.userInput, subject)
				} else {
					serialized, _ := json.Marshal(publicThread(*event.record))
					input = textInput("Mokusei Agent Thread terminal event:\n" + string(serialized))
				}
				input.Presentation = "internal"
				entries, err := c.sendContext(ctx, input, nil, nil)
				if err != nil {
					return err
				}
				c.mu.Lock()
				injection := c.injection
				c.mu.Unlock()
				_, err = c.config.SendSession(ctx, record.ID, input, injection, entries, nil)
				return err
			})
		})
		c.queue.Unlock()
		if err != nil && ctx.Err() == nil {
			kind := "terminal-event"
			if event.userInput != nil {
				kind = "user-thread-input-event"
			}
			c.report(kind, err)
		}
	}
}

// Keep large messages and inline media within native prompt limits. The complete
// accepted input remains in the lifecycle event; the preview is explicitly marked.
func userThreadInputNotification(event plugin.LifecycleEvent, thread model.ThreadRecord) model.AgentInput {
	const previewBytes = 64 * 1024
	data := map[string]any{"event": event, "thread": publicThread(thread)}
	if len(event.Data) > previewBytes {
		end := previewBytes
		for !utf8.RuneStart(event.Data[end]) {
			end--
		}
		metadata := event
		metadata.Data = nil
		var accepted model.UserThreadInput
		_ = json.Unmarshal(event.Data, &accepted)
		data = map[string]any{"event": metadata, "thread": publicThread(thread), "executionId": accepted.ExecutionID,
			"startedNewExecution": accepted.StartedNewExecution, "inputPreview": string(event.Data[:end]), "truncated": true}
	}
	serialized, _ := json.Marshal(data)
	return textInput("Mokusei user direct-to-thread event:\n" + string(serialized) + "\n" +
		"The user has already sent this input directly to the identified child Thread; admission succeeded, not necessarily execution completion. " +
		"Respect the user's direct instructions in that Thread when coordinating, including constraints on follow-ups or integration. " +
		"Do not resend this input or override those instructions. This is a coordination notification, not a new user request addressed to Moku. " +
		"Attachment metadata and browser annotations describe content sent to the child; they do not imply Moku has inspected the files. " +
		"If truncated, use read_thread only when the omitted content is needed for coordination.")
}
func publicWorkspace(record model.ThreadRecord) map[string]any {
	workspace := map[string]any{}
	if record.Cwd != "" {
		workspace["cwd"] = record.Cwd
		workspace["directoryTag"] = ThreadDirectoryTag(record.Cwd)
	}
	if record.Worktree != nil {
		workspace["worktreeCwd"] = record.Worktree.Cwd
	}
	return workspace
}
func publicThread(record model.ThreadRecord) map[string]any {
	result := map[string]any{"threadId": record.ID, "title": record.Title, "tags": record.Tags, "harnessId": record.HarnessID, "workspace": publicWorkspace(record), "updatedAt": record.UpdatedAt, "observation": record.Observation}
	return result
}

// Restart cannot resume a Go tool callback from the former process. Settle its
// audit row before native recovery, even if the native session is recoverable.
func (c *Coordinator) settleStaleTranscript(ctx context.Context, record model.ThreadRecord) error {
	pending := false
	for _, raw := range record.Transcript {
		var item map[string]any
		if err := json.Unmarshal(raw, &item); err != nil {
			return err
		}
		if item["type"] == "message" && item["role"] == "assistant" && item["status"] == "streaming" {
			pending = true
		}
		if item["type"] == "tool-operation" {
			if _, done := item["completedAt"]; !done {
				pending = true
			}
		}
	}
	if !pending {
		return nil
	}
	return c.config.UpdateThread(ctx, record.ID, func(current *model.ThreadRecord) error {
		if !current.Moku {
			return errors.New("Moku audit owner changed during restart")
		}
		at := max(time.Now().UnixMilli(), current.UpdatedAt)
		for index, raw := range current.Transcript {
			var item map[string]any
			if err := json.Unmarshal(raw, &item); err != nil {
				return err
			}
			changed := false
			if item["type"] == "message" && item["role"] == "assistant" && item["status"] == "streaming" {
				item["status"] = "cancelled"
				delete(item, "statusLabel")
				changed = true
			}
			if item["type"] == "tool-operation" {
				if _, done := item["completedAt"]; !done {
					item["completedAt"] = at
					audit := map[string]any{"error": "Moku execution was interrupted during restart"}
					if item["name"] == "read_clipboard" {
						audit["redacted"] = true
					}
					item["result"] = audit
					item["isError"] = true
					changed = true
				}
			}
			if changed {
				encoded, err := json.Marshal(item)
				if err != nil {
					return err
				}
				current.Transcript[index] = encoded
			}
		}
		return nil
	})
}

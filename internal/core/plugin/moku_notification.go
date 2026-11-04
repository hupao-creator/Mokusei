package plugin

import (
	"encoding/json"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"unicode/utf8"
)

// Keep large messages and inline media within native prompt limits. The complete
// accepted input remains in the lifecycle event; the preview is explicitly marked.
func MokuUserThreadInputNotification(event LifecycleEvent, thread any) model.AgentInput {
	const previewBytes = 64 * 1024
	data := map[string]any{"event": event, "thread": thread}
	if len(event.Data) > previewBytes {
		end := previewBytes
		for !utf8.RuneStart(event.Data[end]) {
			end--
		}
		metadata := event
		metadata.Data = nil
		var accepted model.UserThreadInput
		_ = json.Unmarshal(event.Data, &accepted)
		data = map[string]any{"event": metadata, "thread": thread, "executionId": accepted.ExecutionID,
			"startedNewExecution": accepted.StartedNewExecution, "inputPreview": string(event.Data[:end]), "truncated": true}
	}
	serialized, _ := json.Marshal(data)
	return model.AgentInput{Presentation: "internal", Parts: []model.AgentInputPart{{Kind: "text", Text: "Mokusei user direct-to-thread event:\n" + string(serialized) + "\n" +
		"The user has already sent this input directly to the identified child Thread; admission succeeded, not necessarily execution completion. " +
		"Respect the user's direct instructions in that Thread when coordinating, including constraints on follow-ups or integration. " +
		"Do not resend this input or override those instructions. This is a coordination notification, not a new user request addressed to Moku. " +
		"Attachment metadata and browser annotations describe content sent to the child; they do not imply Moku has inspected the files. " +
		"If truncated, use read_thread only when the omitted content is needed for coordination."}}}
}

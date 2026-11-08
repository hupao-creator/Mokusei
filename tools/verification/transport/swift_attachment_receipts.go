package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

// Stop at the same ownership boundary as a disconnected, admitted write that
// has not reached RetainInput. The Swift journal must already own every file.
func (h *swiftFileHost) uncertainAttachmentReceipt(ctx context.Context, args []json.RawMessage) (any, error) {
	var request struct {
		Input model.AgentInput `json:"input"`
	}
	if len(args) != 1 || json.Unmarshal(args[0], &request) != nil || len(request.Input.Parts) != 1 || request.Input.Parts[0].File == nil {
		return nil, errors.New("invalid uncertain attachment receipt fixture")
	}
	id := request.Input.Parts[0].File.ID
	h.filesMu.Lock()
	_, err := h.repository.CanonicalizeInput(ctx, request.Input)
	h.filesMu.Unlock()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(filepath.Join(h.clientRoot, "client-command-journal.json"))
	if err != nil {
		return nil, err
	}
	var journal struct {
		Records []struct {
			ID            string   `json:"id"`
			AttachmentIDs []string `json:"attachmentIDs"`
		} `json:"records"`
	}
	if err = json.Unmarshal(data, &journal); err != nil {
		return nil, err
	}
	for _, record := range journal.Records {
		if record.ID == transport.CommandID(ctx) && len(record.AttachmentIDs) == 1 && record.AttachmentIDs[0] == id {
			return nil, model.NewError("COMMAND_OUTCOME_UNCERTAIN", "Fixture stopped before Thread attachment ownership")
		}
	}
	return nil, errors.New("native command reached HTTP before persisting its attachment owner")
}

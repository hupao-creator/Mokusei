package transport

import (
	"encoding/json"
	"io"
	"net/http"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// ReceiptStatus is observation only. An unknown ID must never admit or replay
// work: the client may have lost the response, or its retention window elapsed.
type ReceiptStatus struct {
	Status string  `json:"status"`
	Result *Result `json:"result,omitempty"`
}

func (s *ReceiptStore) Lookup(id string) (ReceiptStatus, error) {
	if !commandIDPattern.MatchString(id) {
		return ReceiptStatus{}, model.NewError("INVALID_COMMAND_ID", "A valid command ID is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	item, exists := s.receipts[id]
	if !exists {
		return ReceiptStatus{Status: "unknown"}, nil
	}
	if item.Result == nil {
		return ReceiptStatus{Status: "pending"}, nil
	}
	result := cloneResult(*item.Result)
	return ReceiptStatus{Status: "complete", Result: &result}, nil
}

func (s *Server) serveReceiptQuery(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	var request struct {
		CommandID string `json:"commandId"`
	}
	if decoder.Decode(&request) != nil || decoder.Decode(new(any)) != io.EOF {
		s.send(w, 400, resultFailure(model.NewError("INVALID_REQUEST", "A commandId object is required")))
		return
	}
	status, err := s.commands.receipts.Lookup(request.CommandID)
	if err != nil {
		s.send(w, 400, resultFailure(err))
		return
	}
	s.send(w, 200, status)
}

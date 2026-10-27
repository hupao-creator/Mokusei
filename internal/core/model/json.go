// Package model contains the public, language-neutral Mokusei wire records.
// Harness state is opaque JSON: only its owning adapter may interpret it.
package model

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

type Object = map[string]any

// Decode keeps JSON numbers exact instead of converting native IDs to float64.
// A boundary accepts one complete JSON value, never trailing JSON documents.
func Decode(data []byte) (any, error) {
	var value any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		if err == nil {
			return nil, errors.New("multiple JSON values")
		}
		return nil, err
	}
	return value, nil
}

func DecodeObject(data []byte) (Object, error) {
	value, err := Decode(data)
	if err != nil {
		return nil, err
	}
	object, ok := value.(map[string]any)
	if !ok {
		return nil, errors.New("expected JSON object")
	}
	return object, nil
}

// Unmarshal rejects trailing input, preserves numbers in opaque fields, and does
// not allow unknown fields to silently disappear from a public command DTO.
func Unmarshal(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}

func Raw(value any) (json.RawMessage, error)         { return json.Marshal(value) }
func CloneRaw(value json.RawMessage) json.RawMessage { return bytes.Clone(value) }
func IsNull(value json.RawMessage) bool {
	return len(value) == 0 || bytes.Equal(bytes.TrimSpace(value), []byte("null"))
}

// Error is a client-readable failure. Native process diagnostics belong in logs,
// not Code; adapters must never put credentials in Message.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string                 { return e.Message }
func NewError(code, message string) *Error     { return &Error{Code: code, Message: message} }
func (e *Error) Format(s fmt.State, verb rune) { _, _ = io.WriteString(s, e.Code+": "+e.Message) }

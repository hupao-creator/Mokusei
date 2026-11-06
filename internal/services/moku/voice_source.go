package moku

import "github.com/hupao-creator/Mokusei/internal/core/plugin"

// A media ownership generation has one immutable source. Changing pages ends
// that generation; neither buffered audio nor recovery can acquire a new source.
type voiceInputSource struct {
	SuperThreadID string
	Revision      int64
}

func makeVoiceInputSource(id *string, revision int64) voiceInputSource {
	source := voiceInputSource{Revision: revision}
	if id != nil {
		source.SuperThreadID = *id
	}
	return source
}

func (s voiceInputSource) reportID() *string {
	if s.SuperThreadID == "" {
		return nil
	}
	id := s.SuperThreadID
	return &id
}

// Captured at the rejected-input callback, not when configuration was first
// observed pending. Request ID/native generation and source travel together.
type recoveredVoiceInput struct {
	Request plugin.VoiceDelegation
	Source  voiceInputSource
}

package model

// RuntimeServiceActivity counts accepted work and in-flight admission. It is
// also the authority for the host's idle-system-sleep assertion.
type RuntimeServiceActivity struct {
	ActiveTasks int `json:"activeTasks"`
	ActiveVoice int `json:"activeVoice"`
	Admissions  int `json:"admissions"`
}

func (a RuntimeServiceActivity) Busy() bool { return a.ActiveTasks+a.ActiveVoice+a.Admissions > 0 }

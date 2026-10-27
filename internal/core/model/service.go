package model

// RuntimeServiceActivity counts accepted work and in-flight admission. It is
// also the authority for the host's idle-system-sleep assertion.
type RuntimeServiceActivity struct {
	ActiveTasks int `json:"activeTasks"`
	ActiveVoice int `json:"activeVoice"`
	Admissions  int `json:"admissions"`
}

func (a RuntimeServiceActivity) Busy() bool { return a.ActiveTasks+a.ActiveVoice+a.Admissions > 0 }

type HostServiceRestart struct {
	ID             string `json:"id"`
	Generation     uint64 `json:"generation"`
	Status         string `json:"status"`
	RequestedEpoch string `json:"requestedEpoch"`
	ResultEpoch    string `json:"resultEpoch,omitempty"`
	Error          string `json:"error,omitempty"`
}

type HostServiceStatus struct {
	Managed           bool                   `json:"managed"`
	DesiredRunning    bool                   `json:"desiredRunning"`
	Registration      string                 `json:"registration"`
	SupervisorRunning bool                   `json:"supervisorRunning"`
	Epoch             string                 `json:"epoch"`
	Restart           *HostServiceRestart    `json:"restart,omitempty"`
	Activity          RuntimeServiceActivity `json:"activity"`
	ForegroundLeases  int                    `json:"foregroundLeases"`
	PowerAssertion    bool                   `json:"powerAssertion"`
	PowerError        string                 `json:"powerError,omitempty"`
}

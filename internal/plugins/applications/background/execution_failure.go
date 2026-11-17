package background

type executionFailure struct {
	status         string
	nativeErrorSet bool
}

func (e *executionFailure) Error() string { return "Background execution " + e.status }

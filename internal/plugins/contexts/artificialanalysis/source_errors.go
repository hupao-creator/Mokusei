package artificialanalysis

import (
	"errors"
	"fmt"
)

var invalidDocument = errors.New("AA source document is invalid")

type httpFailure int

func (e httpFailure) Error() string { return fmt.Sprintf("AA source HTTP %d", int(e)) }

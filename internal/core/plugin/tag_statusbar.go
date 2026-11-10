package plugin

// TagStatusbar is the complete classification view for one pool. Thread fields
// deliberately exclude execution state, requests, responses and archive history.
type TagStatusbar struct {
	Pool                string                `json:"pool"`
	Revision            string                `json:"revision"`
	Capacity            int                   `json:"capacity"`
	Tags                []TagStatusDefinition `json:"tags"`
	Threads             []TagStatusThread     `json:"threads"`
	Assignments         []TagStatusAssignment `json:"assignments"`
	UnassignedThreadIDs []string              `json:"unassignedThreadIds"`
}
type TagStatusDefinition struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Emoji string `json:"emoji"`
}
type TagStatusThread struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}
type TagStatusAssignment struct {
	ThreadID string `json:"threadId"`
	TagID    string `json:"tagId"`
}
type TagMutation struct {
	Kind             string
	ExpectedRevision string
	TagID            string
	Name             *string
	Emoji            *string
	Assignments      []TagStatusAssignment
}
type TagMutationResult struct {
	Status    string       `json:"status"`
	Statusbar TagStatusbar `json:"statusbar"`
}

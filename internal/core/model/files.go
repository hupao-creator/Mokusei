package model

// AttachmentPolicy is host-owned. Native clients may use it for early feedback,
// but every import and message is validated again by the attachment repository.
type AttachmentPolicy struct {
	ImageBytes   int64 `json:"imageBytes"`
	PDFBytes     int64 `json:"pdfBytes"`
	FileBytes    int64 `json:"fileBytes"`
	MessageBytes int64 `json:"messageBytes"`
	MessageCount int   `json:"messageCount"`
}

// HostFileReference cannot be interpreted as a client filesystem path. Revision
// fences a selected file against replacement before import or download.
type HostFileReference struct {
	HostID   string `json:"hostID"`
	Path     string `json:"path"`
	Revision string `json:"revision,omitempty"`
}

type HostFileEntry struct {
	Reference   HostFileReference `json:"reference"`
	Name        string            `json:"name"`
	IsDirectory bool              `json:"isDirectory"`
	Size        int64             `json:"size"`
	MimeType    string            `json:"mimeType"`
}

type HostDirectory struct {
	Reference HostFileReference  `json:"reference"`
	Parent    *HostFileReference `json:"parent,omitempty"`
	Entries   []HostFileEntry    `json:"entries"`
}

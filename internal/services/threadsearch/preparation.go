package threadsearch

// A complete unchanged document already contains the owner's current search
// projection. Reading status must not ask a Harness to parse that history again.
func currentDocument(source Source, document Document) bool {
	return document.Version == indexVersion && document.SourceHash == source.OwnerHash && len(document.Chunks) != 0
}
func completeDocument(document Document) bool {
	if len(document.Chunks) == 0 {
		return false
	}
	for _, chunk := range document.Chunks {
		if !validVector(chunk.Vector) {
			return false
		}
	}
	return true
}
func prepareSource(source Source, previous Document) (Document, error) {
	if currentDocument(source, previous) {
		return previous, nil
	}
	if source.LoadContent != nil {
		text, err := source.LoadContent()
		if err != nil {
			return Document{}, err
		}
		source.Content = text
	}
	return prepare(source, previous), nil
}

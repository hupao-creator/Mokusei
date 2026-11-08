package threadsearch

// Source extraction runs only after the bounded persisted stamp proved stale.
func prepareSource(source Source) (Document, error) {
	if source.LoadContent != nil {
		text, err := source.LoadContent()
		if err != nil {
			return Document{}, err
		}
		source.Content = text
	}
	return prepare(source), nil
}

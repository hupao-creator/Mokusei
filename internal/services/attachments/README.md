# Attachment storage

The repository stages path, byte and streaming imports through one bounded
writer. It normalizes the stored display name and basename together, removing
leading dots and unsafe characters. A single-segment dotfile has no separate
extension: `.env` becomes `env`, `.gitignore` becomes `gitignore`, and
`.config.json` becomes `config.json`. Normalization never duplicates an extension.

Thread ownership retains admitted files independently of temporary composer
chips. Preview and cleanup validate that ownership and the immutable content.
The real import, retention, preview and cleanup boundaries are exercised by
`./scripts/go.sh run -race ./tools/verification/runtime-helpers`.

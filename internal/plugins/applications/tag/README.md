# Scoped semantic tags

[plugin.go](plugin.go) registers a per-directory Tag Agent. Each scope, including Inbox, owns a pool of at most **five** semantic tags. The agent classifies eligible ordinary threads, including archived threads, into exactly one tag from that pool. Runtime capability bindings enforce scope; the agent cannot assign another directory's threads or mutate directory labels.

The agent observes accepted input and completed/failed/interrupted execution facts, plus its scoped inventory events. It uses the shared background runner with lazy initialization and idle disposal. Configuration follows Moku or an independent profile. [overview.go](overview.go) sends scoped selection requests through the host's Overview capability.

## Names and emoji

`create_tags` requires `{name, emoji}` entries. `merge_tags` requires the target emoji; `rename_tag` preserves it unless supplied. Duplicate creation returns the existing definition. Unused tags may be deleted; an in-use tag must be merged instead. Renames/merges update affected assignments atomically.

[Mutation tools](tools.go) validate complete argument shapes before requesting batch write authority. Unknown nested fields, missing required fields and `null` or non-string optional decorations reject the call; omitted decorations preserve existing values, while an explicit empty description remains a supplied value. Runtime retains responsibility for tag normalization, pool limits and scope authorization.

Text names are the normalized identity; names/assignments cannot contain emoji prefixes. [taglabel](../../../services/taglabel/) validates complete Unicode Emoji 16.0 sequences. Invalid nonempty newly generated emoji falls back to `🏷️`; missing/empty fields reject. Stored metadata and Swift decoding are strict and do not repair invalid definitions.

Every public thread envelope includes `tagEmojis`, even when empty. Keys match semantic tags, excluding directory tags. Emoji-only changes publish revisions and update Report source decoration. [generate-tag-emoji.py](../../../../scripts/generate-tag-emoji.py) generates the Swift table from the pinned data; the parity test checks agreement.

Overview displays emoji and name separately from the identity, groups aliases with identical membership, and includes singly used semantic tags. Directory labels come from [directorytag](../../../services/directorytag/directorytag.go). [Overview presentation](../../../../app/macos/Sources/Host/Overview/README.md) owns visual filtering and motion.

Verification: `make check-directorytag`, `./scripts/go.sh test -race ./internal/services/taglabel ./internal/plugins/applications/tag ./internal/core/runtime` and the runtime integration replay.

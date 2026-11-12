# Local embedding process

`MokuseiEmbedding` is a Runtime-owned, serial NDJSON process. It uses the pinned
official LiteRT-LM macOS binary and EmbeddingGemma 2 Text 270M INT4 weights.
The small Swift adapter calls the published C embedding API directly, avoiding a
clone of the multi-gigabyte SDK history during each fresh dependency resolution.
URLSession owns downloads so the native system proxy policy applies. A complete
size/hash-verified file is atomically published; model assets contain no user text.
Only `embed` loads the engine. The Runtime prioritizes queries, bounds work and
retires the whole process after inactivity to release native allocations.

The handshake declares the complete embedding space and byte budget. Space identity
is derived from the weights hash, task prefixes, output dimensions, normalization
and preprocessing/runtime revisions, rather than a separately maintained label. Query and
document task prefixes belong here, not in retrieval. Native inference is
synchronous and cannot be interrupted through the Swift API; the owning Runtime
fences late results and can terminate the isolated process during teardown.
Library output goes to stderr; stdout is reserved for the private protocol.

The process accepts `--model-directory /absolute/path`, or `--describe` for a
model-independent linkage/protocol probe. It never opens the application database
or discovers Harness credentials. New model families implement the provider
contract with their own preprocessing and space identity.

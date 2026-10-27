# Local embedding provider

[assets.go](assets.go) pins `google/embeddinggemma-2`, GGUF Q8_0 revision `bfcd298762cc34d0357ece5ebdd31791a3a374d8`, and the official `llama.cpp-b11748` server archive. Exact lengths and SHA-256 digests are checked before publication. Production engine assets are defined for macOS arm64 and x86_64. Model/source and engine licenses remain separate; the engine archive's license is retained.

Assets live under the profile's `search-models/embeddinggemma-2` directory. [Thread search](../threadsearch/README.md) requests preparation automatically. Download uses a separate bounded HTTP path; product requests cannot supply arbitrary endpoints, executables or hashes. Archive validation rejects escaping paths and incomplete or mismatched assets.

[provider.go](provider.go) launches an owned `llama-server` process on authenticated loopback. Inference ignores proxy variables, only dials `127.0.0.1` and refuses redirects. Text is sent to `/v1/embeddings` as a string, with `model: google/embeddinggemma-2` and float encoding. It uses mean pooling, 768 dimensions, finite/nonzero vector validation and normalization. Query/document prefixes are `task: search result | query: …` and `title: … | text: …`.

The helper uses one inference slot, context/batch/ubatch 8192 and four CPU threads, with Metal where available. Startup/calls have bounded deadlines. Idle timeout defaults to two minutes. Cancellation and shutdown join the owned process group; an uncertain cleanup poisons reuse instead of allowing overlapping owners. Download cancellation, clear and service shutdown retain their own joined lifecycle.

The model and engine download may use the network. Thread text and search inference stay on the host. The provider does not interpret input strings as URLs, files or tool instructions.

Verification is part of the [thread-search replay](../../../tools/verification/thread-search/README.md), which supports synthetic hash-verified assets and an explicit real-engine mode.

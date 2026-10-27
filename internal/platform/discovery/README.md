# Native discovery reads

`Cache[T]` shares bounded read-only native probes by the owning adapter's key.
Readers cancel independently; the final departing reader cancels an unfinished
probe. `Close` seals admission and joins every active probe, including replaced
ones. Adapters must drain their native process in the probe before it returns.
Published values are immutable; public projections clone mutable data.

Explicit refresh supersedes an ordinary flight for that key. Concurrent explicit
refreshes join. Superseded readers may finish, but only the current flight can
publish. Failed, cancelled and timed-out probes cannot overwrite the last success;
a failed refresh does not renew its freshness. The cache retains at most 64
successful keys. This cache is not an execution or authentication authority.

`Identity` hashes the native environment and metadata of adapter-selected files.
It never reads file contents, logs environment values, or writes snapshots to disk.
Adapters own the list of native configuration paths. File metadata cannot observe
keychain/remote account changes or every transitive native configuration include;
TTL, explicit refresh and live native execution checks remain necessary.

`make check` includes the cancellation, close/drain, refresh publication, failure
retention and profile/file identity tests with the race detector.

Adapters wrap cleanup errors with `Cleanup`. The cache retains this ownership
failure even after the reader leaves, fences replacement acquisition and reports
it from Close. Ordinary native read failures do not poison other keys.

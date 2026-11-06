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

`GetStale` is the routing-only alternative to `Get`: an immutable successful
same-key entry returns immediately, including during explicit refresh and after
TTL expiry. Expired entries start a cache-owned probe; a cancelled foreground
reader does not cancel that background owner. Only a cold lookup waits. Failed
refreshes preserve the complete snapshot without renewing freshness, with a 30-second
warm-retry cooldown. Cleanup ownership errors stop further probes but do not
hide an existing routing snapshot; strict acquisition still reports them.

Callers must only publish complete, nonempty model inventories on this path.
Execution/default resolution keeps using strict `Get` and native admission.
Caches are in memory and instance-owned, not persisted across process restarts.
Close seals even stale reads, cancels every active probe and joins cleanup.

`SourceIdentity` is a bounded routing dependency fingerprint for a resolved
launch. It visits lexical and canonical workspace ancestors, the owning native
namespace, symlinks and recognized literal references (including `{file:...}`).
Configuration text is hashed, not logged or persisted. The bound is 4096 paths,
4 MiB per text file and 16 MiB per read. Inspection errors/limits reject identity
rather than silently skipping inputs. Runtime-owned caches/history and dependency
package directories are excluded from implicit directory walking. Computed
imports and arbitrary native reference syntax are not a complete dependency
manifest; they cannot support an affirmative source attestation. The probe must
use the captured resolved executable/environment and compare the source again
after acquisition. External editors are not part of a filesystem transaction.

Evidence-checked routing caches are separate from ordinary enumeration caches.
An unknown-source result may remain useful for ordinary explicit selection, but
cannot publish over a trusted routing snapshot. Cache presence alone does not
establish the caller's source evidence.

File generation fingerprints include replacement/change metadata where the
platform provides it (device/inode/ctime), excluding access time. Keeping an old
mtime/size while replacing a binary therefore does not silently reuse its version
fact, and merely reading/executing it does not invalidate the lookup.

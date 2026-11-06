# Codex discovery compared with T3 Code

No `CodexProvider.ts` was found in the searched local Desktop/worktree, temporary,
Developer or Projects locations (including a hidden-file search of Desktop and
temporary directories). The comparison used GitHub sources instead. The fetched
main contents of `CodexProvider.ts`, `ProviderRegistry.ts` and
`providerStatusCache.ts` exactly matched revision
`2e39f1d7dec44c98a4cabdaf99d3d99209f770c0` during this investigation. The links below
pin that revision; no claim is made about future main.

| Behavior | T3 evidence | Moku candidate |
| --- | --- | --- |
| Enumeration | `requestAllCodexModels` follows every truthy nextCursor | Follows all pages; explicitly requests hidden models and limit 100; additionally rejects malformed pages, repeated cursors/IDs and missing completion |
| ChatGPT refresh | Takes a first complete list, polls fetched_at every 100ms for up to 3s, and rereads after a post-spawn timestamp | Same best-effort hint; a single 3s budget also covers account-kind check and reread; unchanged cache files are not reparsed every tick |
| Refresh timeout/fallback | Uses first list when the refresh hint times out; accepts native cached/bundled metadata | Same; also keeps first list on reread RPC/page errors or empty reread, rather than failing a usable acquisition |
| Other accounts | Does not wait for the ChatGPT refresh hint | Same; failed account-kind lookup keeps the directory and is not an auth-success assertion |
| Config/usage enrichment | Config read has its own 3s timeout and errors degrade to absent enrichment | Routing config/auto-review/plugin enrichment shares a 3s budget and cannot invalidate a valid directory; ordinary defaults/creation validation remains separate |
| Probe failure | Provider status is error/timeout; registry retains eligible old noncustom model rows | Failed/empty acquisition retains the whole previous successful same-key snapshot; without one it reports an error, never a partial directory |
| Persistence | Atomically saves per-instance status; hydration checks instanceId, driver and enabled state and merges current custom models | Memory-only Harness cache; restart reacquires native inventory, which may itself use native disk cache |
| Refresh scheduling | Managed provider refresh serializes and runs at startup/settings/manual/health intervals | Routing cache returns stale data immediately; 5min expiry triggers bounded background refresh, with 30s failure cooldown; ordinary settings refresh remains separate |
| Policy/provenance | No cryptographic/formal source-completion requirement in the inspected discovery path | No static-file/version pin, strict-config flag or source-completeness gate; source remains unknown in schema |
| Client identity | Sets originator at spawn to match initialization | Captured executable/environment with matching `mokusei_desktop` spawn/initialize identity |

Sources:

- [Codex enumeration and refresh](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/apps/server/src/provider/CodexProvider.ts#L363)
  and [probe/account/enrichment](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/apps/server/src/provider/CodexProvider.ts#L540).
  Its outer status probe budget is 20s. Moku retains its existing 60s owned probe
  budget; cleanup can outlast the work budget and remains joined.
- [Status failure and fallback](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/apps/server/src/provider/CodexProvider.ts#L743)
  uses settings-derived fallback/custom rows after failure, while registry
  [model merging](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/apps/server/src/provider/ProviderRegistry.ts#L171)
  retains old rows according to provider status. Moku neither invents custom
  fallback rows nor unions a failed page prefix into the previous snapshot.
- [Disk status cache](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/apps/server/src/provider/providerStatusCache.ts)
  and [managed refresh lifecycle](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/packages/provider-core/src/server/managedProvider.ts).
- T3 also applies [model catalog presentation overlays](https://github.com/pingdotgg/t3code/blob/2e39f1d7dec44c98a4cabdaf99d3d99209f770c0/apps/server/src/provider/codexModelCatalog.ts)
  and version-based update hints. Moku preserves native returned choices; it does
  not reproduce these presentation/custom-model layers.

The user's follow-up extends usable-native-snapshot admission to Claude,
OpenCode and Pi, removing this candidate's fixed proof rejections there too.
That is not a claim of identical T3 behavior or attested completeness for those
protocols. All selected targets still need a usable directory; creation still
revalidates the chosen native model, and Runtime retains final execution/input
protection. Warm failure state is exposed as a retained-snapshot note while
source completeness remains false. No native runtime or regression tests were
executed for this comparison.

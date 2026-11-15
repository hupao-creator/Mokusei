# Agent reading projection replay

Exports the production Codex, Claude, Pi and OpenCode `agent-summary` renderer
projections for the native Agent reading replay.

```sh
./scripts/go.sh run ./tools/verification/agent-reading -output /private/tmp/mokusei-agent-reading.json
MOKUSEI_AGENT_READING_FIXTURES=/private/tmp/mokusei-agent-reading.json \
  xcrun swift test --package-path app/macos --filter AgentReadingProjectionTests
```

The staged production app replay owns the same flow:

```sh
python3 tools/verification/reading-presentation/run.py --agent-reading
```

The Go fixture crosses each real `plugin.SessionStateAdapter` with the
`agent-summary` purpose and an explicit native message target. It runs while
running/waiting/completed/failed/interrupted in each package test; the exported
native fixture uses the completed case. The native test mounts the manifest
conversation plus the projected row, requires the `.reading` scope and rejects
`.row` or `.execution` requests. Hidden bodies are absent from the wire and the
mounted accessibility tree.

`TestAgentReadingWireBudget` records UTF-8 wire bytes, source state bytes and
projection allocations. The native replay records decode time for the projected
row state. A representative run on the completed target fixture:

| Harness | Wire bytes | State bytes | Projection allocs | Native decode |
| --- | ---: | ---: | ---: | ---: |
| Codex | 1707 | 2900 | 632 | 0.7-9.0 ms |
| Claude | 1417 | 1646 | 390 | 0.5-4.2 ms |
| Pi | 1151 | 1320 | 121 | 0.5-2.6 ms |
| OpenCode | 1551 | 2059 | 682 | 0.5-2.7 ms |

The decode range includes the first cold admission and warm reads; the test
prints each observed value.

These are fixture measurements for the projection boundary, not a claim about
CPU, frame rate or a real provider session. Increasing hidden reasoning/tool
bodies does not change the summary wire bytes; the package tests grow those
bodies and require byte-stable output.

The execution-link replay also builds this producer once and supplies
`MOKUSEI_CODEX_READING_PROJECTOR`. Its `-codex-input` mode projects each dynamic
native state/scope through Codex's production `ProjectRenderer`; the Swift
fixture does not implement a second agent-summary filter. Ordinary SwiftPM
execution-link tests build the same producer once on demand.

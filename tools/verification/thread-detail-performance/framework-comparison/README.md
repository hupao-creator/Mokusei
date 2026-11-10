# Markdown framework comparison

This standalone package links the current production `NativeMarkdownView`,
Textual and MarkdownUI into one Release executable. Third-party dependencies
are pinned here and do not change the application package. Run on a Mac with a
foreground graphical session:

```sh
python3 tools/verification/thread-detail-performance/framework-comparison/run.py
# Include the exact bytes of a private reply without committing its contents:
python3 tools/verification/thread-detail-performance/framework-comparison/run.py \
  --source /absolute/local/reply.md
```

The default runs three fresh processes per renderer/fixture, rotating the three
renderer positions. Synthetic fixtures cover 160 paragraphs and 40 sections of
headings, lists, tables and code. All builds finish before measurement. An
exclusive native-replay lock prevents overlap with other cooperating graphical
replays. Keep the benchmark window foreground; loss of focus, thermal pressure,
missing output or a failed geometry/scroll prerequisite invalidates the sample.

Each process uses the actual public renderer, raw Markdown input, a shared
900×700 SwiftUI ScrollView/NSHostingView, 20pt padding, 16pt Inter body text,
light appearance and enabled selection. Candidates use their GitHub styles;
production retains its production typography and spacing. Their document heights
are recorded rather than assumed equal. All content remains normally mounted;
the harness introduces no lazy container or view virtualization.

Measured phases are fresh-process mounting, remounting in the same process,
120 normalized scroll positions at a requested 60Hz cadence, and 900→500→900pt
resizing. Mounting includes parsing and native presentation work. Convergence
requires nonzero document height, at least 200ms of observation and 150ms of
unchanged geometry, with identical layout/display flushes for all renderers.
The intentional observation floor is included in wall times. CPU is whole-process
user+system time. Scroll callback lateness is not optical FPS. Native view counts
are inspected after warm mounting; footprint is sampled at phase boundaries,
not a measured peak.

This is a renderer-component comparison. It excludes transport, Harness
projection, panel travel, production paced admission and line entrance. It
cannot certify complete Thread navigation performance or feature equivalence.
No streaming workload is included. Production local-link previews and candidate
syntax highlighting keep their renderer defaults, so this is not a pixel-identical
or feature-ablated comparison.

Use `--capture --rounds 1` for a separate visual run. Native AppKit captures of
the top, middle and bottom are retained after mounting; their timings must not
be pooled with normal measurements. These captures are diagnostic images, not
WindowServer presentation timestamps or a complete selection/copy oracle.

Evidence is saved under `.scratch/markdown-framework-comparison/<timestamp>`:
source/build identities, resolved dependencies, raw per-process logs and results,
fixtures, samples and median/min/max summaries. An optional private fixture stays
only in this local directory. Review summaries alongside raw results; a successful
process is not a claim that every Markdown extension renders equivalently.
The local SwiftPM build directory remains available: candidate generated resource
accessors may resolve their recorded build-directory fallback, while production
uses the staged resource bundle. This experiment does not certify distribution
packaging of either candidate.

This manual diagnostic runs when comparing a renderer or investigating a target-
Mac rendering regression. Ordinary hosted CI does not run its timing workload
and no performance threshold is added to the merge gate. The package build and
actual local comparison validate this tool; they do not replace required hosted
checks for repository changes.

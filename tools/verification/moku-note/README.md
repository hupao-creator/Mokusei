# Production Note replay

After `make check ARGS=`, run from the repository root:

```sh
MOKU_NOTE_NATIVE_FIXTURE=.scratch/note-read-awareness/records.json ./scripts/go.sh run -race ./tools/verification/moku
python3 tools/verification/moku-note/run.py --skip-build --records .scratch/note-read-awareness/records.json --evidence .scratch/note-read-awareness/evidence
./scripts/go.sh run -race ./tools/verification/moku -swift-note-exposure
```

The first native mode mounts the production Dock and Markdown renderer with
Coordinator-generated records. It checks short-note dwell, opening/closing,
click-to-input and note-to-input focus, ignored horizontal swipes,
in-place updates, unsupported content, long-note gaps and complete overlapping
viewport coverage, plus pending submission failure/retry and voice presentation.
The Go/Swift mode starts a temporary authenticated Runtime, sends the actual
tracker's receipt through `RuntimeClient`, and checks the exact persisted text
and next fake Harness context. Neither mode opens a user's runtime/profile or
uses a paid provider/microphone. Exposure is presentation evidence, never proof
of understanding or approval. Reduce Motion and live media remain source-reviewed.

[`native_replay.py`](../native_replay.py) stages the fixture, replay source,
link objects, Swift modules, headers, framework and resource bundles in a unique
temporary directory. The app starts in its own temporary workspace and receives
only temporary input/output paths. After exit, the Python launcher copies evidence
back to `--evidence`; the GUI app never writes the Desktop checkout. Production
resources use the packaged `Contents/Resources` path. A startup guard validates
the paths and bundles before mounting Cocoa and writes `runtime-isolation.json`
with its PID, cwd, arguments and resource paths. `launch.json`, stdout/stderr,
the result and `cleanup.json` are retained with the evidence.
Exposure failures also print the submission/catalog events, foreground state and
mounted viewport/tracker diagnostics. They distinguish a missing completed view
from a rejected Runtime receipt without changing arming or coverage admission.

Finish SwiftPM builds before staging. Native replays acquire one nonblocking
graphical-session lock. `--isolation-only` validates packaging without mounting
UI; it does not substitute for the functional replay. `--timeout N` bounds app
runtime (default 180 seconds). A timeout/cancellation sends SIGTERM only to the
PID whose executable matches this unique staged app; stopping `open -W` alone
does not retire a LaunchServices app. Diagnose a permission/focus error from the
retained logs before retrying. Do not click permission buttons or grant Desktop
access to make a replay pass.

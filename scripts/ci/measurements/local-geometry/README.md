# Local retained-return observation experiment

On local checkout `b722105` (product tree
`cafbe498a6238fb0286fce6806dd539cada1fbd4`), the current-source Swift test
targets built successfully. A candidate test fixture then used actual geometry
change callbacks to signal an immediate reread of the native front view. It
retained the original 40–60% band, current-view/owner checks, return direction,
content and parent-retention assertions.

The seven-case native capture replay passed with exit 0 in 94.041 seconds
(64.301 seconds inside the test process). It recorded 64 opening observations;
the return was submitted at actual x=687 for a width of 1180, with one current
root and one current front anchor and matching production progress. The return
check occurred 104.429 ms after close. Its exact staged test-source SHA-256 was
`e4cbf1367c02b3629914658909b5bdc85fac446d857d883e17a0225d0df911b1`.

A separate negative control temporarily changed only this fixture's opening
duration from 1.2 seconds to 0.000001 seconds. The same seven-case launcher
exited 1 in 85.626 seconds: the retained-return test timed out under its existing
three-second condition, observed x=0, 1180 and 903, and never submitted close.
The other six tests passed. This is an expected failure, not a successful
normal replay. The modified source SHA-256 was
`af7ab7de830908d28459ff62374de03e66397b78e8e0cd9925dfce63cc63c701`; the
candidate was restored byte-for-byte afterward. The control patch, actual
reports, logs and source/binary provenance are retained in this directory.

Review subsequently added an explicit pre-input three-second deadline check to
prevent a late geometry callback from submitting a return after the old budget.
The changed source SHA-256
`0034c7321ba8bb31e44f8d9d006a5d6fe8f44560053b014b98a9350bf436f5fa`
then passed the same seven-case native replay with exit 0 in 85.861 seconds
(64.173 seconds inside the test process). It observed x=694.5 at width 1180,
two matching anchors, and the return check 101.606 ms after close. The
[guarded report](guarded-report.json), log and provenance retain this later run.

These local results do not certify the eventual PR merge tree or prove hosted
failures harmless. Full screenshots and logs remain under
`/private/tmp/mokusei-ci-geometry-local/{positive-scratch,negative-scratch,guarded-scratch}`.

## Shared compiler-cache review

The cache used across these three staged launches contains `CAtomic`,
`cmark_gfm` and `cmark_gfm_extensions` PCM files as well as SDK modules; the
[observed filenames](dependency-module-cache.json) disprove the earlier claim
that it contains only SDK modules. After a staged app had been cleaned up,
`clang -module-file-info` on one old `CAtomic` PCM exited 1 because its staged
module map no longer existed ([output](orphan-pcm-info.log),
[exit](orphan-pcm-exit.txt)). Later staged launcher compilations in this same
cache succeeded; this inspection alone does not establish that they reused the
orphan, nor does it test every dependency-change invalidation case. The cache is
job-local and is discarded with the job; app objects, executables and test
outcomes are still produced independently for each launch.

A focused follow-up used the actual `NativeReplay` staging and compiler path
twice with one shared cache. It appended a different constant to each staged
`CAtomic.h` copy and ran the two newly compiled executables: they printed 11 and
22 respectively, both with exit 0. Compilation took 2.583 and 0.797 seconds;
this small import probe is not an end-to-end CI speed measurement. It covers
separate staging paths, not every possible same-path dependency mutation.
The [first attempt](cache-invalidation-attempt1.log) stopped before compiling
because the copied checkout header was read-only. The second attempt made only
the temporary staged copies writable and passed; its [script](cache-invalidation-probe.py.txt),
[log](cache-invalidation-attempt2.log) and [receipts](cache-invalidation-results.json)
record the inputs and outputs.

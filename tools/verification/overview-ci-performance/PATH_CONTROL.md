# Fixed-product staged-path diagnostic

This is an isolated control for a side-associated source scheduling spike seen in
the preceding A/A experiment. It is not an optimization result or a replacement
for the foreground Overview A/B benchmark.

The diagnostic branch is based on `ae067baebbe5f3bde51bde966ef90cbe69ed8b31`.
The one product build is fixed at
`69c30b9a3356ca3a5c9a4de9ce78f1b683960125`, with product-input SHA256
`cb0f8221d4f679a4e5e2bb9df84e24a21a504e6832de32cf29fe7b3f3dc0c2b9`.
The existing thirteen measurement inputs must still hash to
`7da390645f45624de3f8e77da8472387bb292e9c92c5544de8c59812917e7254`.
The control refuses a changed input inventory. Its new launcher/test/workflow
are separately identified and do not change any original measurement source.

## Single build and physical packages

The existing Release build flags and `NativeReplay` compiler build the product,
probe and Core once. P is the original staged app. Q's `NativeReplay` constructor
stages its own workspace and resource manifest, then receives a complete copy of
P's signed app and the exact same Core executable. Q is never compiled or signed.
P and Q keep `com.mokusei.overview-performance`; they use distinct temporary
directories and separate physical files, not hard links.

Before the first measured process and after the last, the artifact records UI
and Core SHA256, complete relative-path content/permission/symlink manifests,
actual resource-bundle paths, and app codesign verification plus CDHash. Core's
original signature is verified if present, or explicitly recorded as unsigned;
the diagnostic never changes it. P/Q content/signature equality is mandatory.
Every run also checks its actual package locations and executable device/inode,
and uses the original startup, result, Core-parent-PID and cleanup validators.
The shared manifest is not copied from P to Q. No file hash/signature inspection
is added inside warmup, formal or tail CPU windows.

## Prespecified execution

Every cell starts a fresh UI/Core process and profile. Both packages remain on
disk; after the first dual-path group both have been launched by LaunchServices.
No package is unregistered between cells.

| Run | Group | Logical label | Actual package |
| --- | --- | --- | --- |
| 1 | D_AB | A | P |
| 2 | D_AB | B | Q |
| 3 | S_AB | A | P |
| 4 | S_AB | B | P |
| 5 | S_BA | B | Q |
| 6 | S_BA | A | Q |
| 7 | D_BA | B | Q |
| 8 | D_BA | A | P |

Only S4 is measured: N40, four fully visible running cards, five seconds of
load-bearing warmup followed by the original twenty-second formal interval.
The raw clock v2 handshake, source protocol v2, FIFO256, actual enqueue 50ms
gate, 1,000 planned events, real Store/publisher/transport/catalog path, final
model/hash checks, original tail budget and owned-process cleanup all remain.
No QoS, App Nap, bundle identity, activation order, source timing or animation
change is introduced. No automatic rerun replaces an invalid cell.

`reportKind` is `staged-path-control`. A/B are labels within a diagnostic group,
not product revisions. The report exposes actual P/Q mappings and all raw CPU,
input, lateness, full-work CPU, model-convergence and memory records. Four named
groups are evaluated independently; the ordinary product `paired_results`
aggregation is not used. Unexpected errors or uncertain cleanup stop subsequent
cells after preserving the in-flight row and original evidence.

## Interpretation limits

If the two dual-path reference groups do not reproduce the prior phenomenon,
this control cannot attribute its cause. If a pattern changes with path reuse,
that is evidence about this one runner's startup/path history, not proof that
LaunchServices, App Nap or any one subsystem caused it. Labels are correlated
with the prescribed chronology, so this small control cannot eliminate all
time/order effects. The production cloud's seed and phase remain random.

Formal CPU still contains the existing lightweight observers. It has no formal
GPU/present count or WindowServer pixel evidence. A green same-path group is not
a product fix, and no result calibrates or revalidates historical runners.

The new workflow triggers only on a push to
`diag/overview-ci-path-20261031`; it changes no PR or required check workflow.
Local Python tests check staging identities, exact mappings, original validation
calls, failure retention and cleanup. macOS compilation, signatures and the
eight actual processes still require this isolated CI run.

# Super Thread collection ink and glass integration

The product changes from `36077b20bbb366d7e0463ab3eda7150a8ae07a9b`
are integrated without its demo files or demo ancestors `5fc5e58` and `285ae1a`.

Cover travel and stationary metadata ink share one 460ms ease-in-out clock.
Backward paging mirrors the shared `ThreadCardInkMask`; Agent excerpts retain
their existing 280ms timing. Cancellation retires the mask identity while keeping
selected metadata and WebKit covers mounted.

Native carousel buttons and Menu remain disabled during travel. The disabled
boundary sits inside the surrounding glass and the button style preserves its
label appearance. Metadata uses pointer/accessibility gates and guarded actions.
Integration review additionally found that the archive context menu needed the
same gate: open and archive now recheck a callback reading the collection's
current selection and motion state, including when a native menu was already
open. Previously admitted archive operations retain their completion ownership.

## Evidence and limits

The source implementation reported successful build, lint, production-component
screenshots and AX interaction checks. Its final native regression attempts each
passed 6 of 7 tests; the complete group did not pass. The first decoration/cloud
capture failed waiting for complete/BGRA/opaque frames; the retry failed foreground
admission with `appActive=false` and `windowKey=false`. These are distinct failures;
the retry does not establish that the first failure was harmless. Assertions,
timeouts and skip policy are unchanged.

Source evidence remains in the originating worktree under
`.build/super-collection-transition/native-final-failed/` and
`.build/super-collection-transition/native-final-retry/`. Demo fixtures, captured
images and their scripts are deliberately excluded from this product integration.
Their results predate the additional archive gate and cannot certify that gate.

The supplied recording's whole-glass blackening was not fully reproduced.
The change addresses a specific disabled-environment/label-dimming path;
it does not prove that every recorded material change has been eliminated.
Physical trackpad, full keyboard and VoiceOver interaction, and the unresolved
cloud capture remain outside completed acceptance. This local integration does
not restart the user's application or publish CI results.

## Local integration verification

The final product and existing test targets compile with
`xcrun swift build --package-path app/macos --build-tests --force-resolved-versions --skip-update --disable-index-store -j 2`.
The initial build took 129.35s; a subsequent incremental build after the last
source edit passed in 6.64s. Logs remain under
`/tmp/mokusei-collection-product-integration/`.
Swift parsing, diff review and changed local documentation links also passed.
No new tests or graphical replay were added or run for this integration;
the additional archive gate is compiled and reviewed, not live-interaction
certified. No application was restarted and no changes were pushed.

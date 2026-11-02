# Tag first-frame event diagnostics

The 4-A run in [41398629007](../hosted-ab-41398629007/README.md) retained only
one complete frame during the first 400 ms visit. It did not retain the input,
view appearance or drain time, so neither a missed capture nor a product defect
can be established from that result.

The instrumented test records those event times and the input-time app/window
state alongside the original frame timestamps and bitmaps. It keeps the three
visits, 400 ms capture duration, minimum two-frame requirement and original
pixel oracle unchanged; view appearance is diagnostic and is not a passing
criterion. A current-source Swift test-target [build](build.log) succeeded in
18.15 seconds with the recorded [input hashes](inputs.json). The build alone is
not an AppKit/WindowServer replay or hosted CI result.

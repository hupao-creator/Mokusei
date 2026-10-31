# Native input test support

This Objective-C target is a dependency of the Host integration tests only.
`MokuHoldInputClock` uses its typed C function to create and post timed mouse
events on the calling serial worker. The application reference, window number
and coordinates are captured on the main actor before that worker starts.
The bridge accepts only the left-button drag and release types used by this
fixture. It creates and posts the event in one autorelease pool, returns whether
posting succeeded, and never looks up the shared application, a window or a view.

Apple explicitly permits
[posting events from secondary threads](https://developer.apple.com/documentation/appkit/nsapplication/postevent(_:atstart:)).
The Swift SDK imports `NSApplication.postEvent` with inherited main-actor
isolation. This small Objective-C boundary uses the documented thread contract
without unsafe Swift isolation overrides, unchecked sendability or warning
suppression. The Swift clock still owns all deadlines, synchronization,
cancellation, actual-post receipts and behavioral assertions. The bridge performs
no dispatching or waiting of its own.

SwiftPM builds this module through `Package.swift`. The
[isolated reading replay](../../../../tools/verification/reading-presentation/README.md)
also compiles these same three inputs: `NativeInputSupport.m`,
`include/MokuseiNativeInputSupport.h` and `include/module.modulemap`. Its runner
copies them into the temporary replay build directory and compiles the Objective-C
object with ARC and warnings as errors, using the replay's selected macOS SDK and
deployment target. The Swift replay imports the staged module map and explicitly
links that object; it cannot obtain test-only objects from the production app's
link list.

The replay's `launch.json` manifest records `nativeInputSupport` with the three
input SHA256 hashes, staged paths, compiler command and object SHA256. The input
and command evidence is retained even if bridge compilation fails. Only the
Moku composer and isolated-input modes build this fixture. It is not linked into
the application or formal Overview CPU probe. The package manifest change remains
part of the performance runner's product-input hash; it is not excluded merely
because the new dependency belongs to a test target.

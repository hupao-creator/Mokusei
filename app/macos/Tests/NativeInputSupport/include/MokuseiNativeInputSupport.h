#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Creates and posts only the drag/release events used by the timed input fixture.
/// The caller captures the application, coordinates and window number on MainActor.
FOUNDATION_EXPORT BOOL MokuseiPostMouseEvent(
    NSApplication *application,
    NSEventType type,
    NSPoint location,
    NSTimeInterval timestamp,
    NSInteger windowNumber,
    NSInteger eventNumber);

NS_ASSUME_NONNULL_END

#import "MokuseiNativeInputSupport.h"

BOOL MokuseiPostMouseEvent(NSApplication *application, NSEventType type,
                          NSPoint location, NSTimeInterval timestamp,
                          NSInteger windowNumber, NSInteger eventNumber) {
    if (type != NSEventTypeLeftMouseDragged && type != NSEventTypeLeftMouseUp) {
        return NO;
    }
    @autoreleasepool {
        NSEvent *event = [NSEvent mouseEventWithType:type
                                          location:location
                                     modifierFlags:0
                                         timestamp:timestamp
                                      windowNumber:windowNumber
                                           context:nil
                                       eventNumber:eventNumber
                                        clickCount:1
                                          pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
        if (event == nil) {
            return NO;
        }
        // AppKit documents secondary-thread posting; no window or view is read here.
        [application postEvent:event atStart:NO];
        return YES;
    }
}

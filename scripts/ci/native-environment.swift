import AppKit

print("Native CI screens:", NSScreen.screens.map { ($0.frame, $0.backingScaleFactor) })
print("Reduce Motion:", NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
print("Reduce Transparency:", NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
precondition(CGSessionCopyCurrentDictionary() != nil && !NSScreen.screens.isEmpty)
precondition(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
precondition(!NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)

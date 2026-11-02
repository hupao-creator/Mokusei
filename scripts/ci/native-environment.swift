import AppKit

print("Native CI screens:", NSScreen.screens.map { ($0.frame, $0.backingScaleFactor) })
print("Reduce Motion:", NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
print("Reduce Transparency:", NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
guard CGSessionCopyCurrentDictionary() != nil && !NSScreen.screens.isEmpty,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else {
    fputs("Native verification requires a logged-in display with motion and transparency enabled. No tests certified.\n", stderr)
    exit(1)
}

"""Discovered Swift methods executed only by a mandatory native replay."""
import re

NATIVE_METHOD_OWNERS = {
    "MokuseiSettingsIntegrationTests.SwiftUIOverviewInteractionTests/titleReversalAndVisibilityCancellationSettlePixels()": {
        "group": "native-capture", "check": "tag-glass-captures", "marker": "TITLE_INCOMING_MOTION_CONFIRMED",
    },
    "MokuseiSettingsIntegrationTests.SwiftUIOverviewInteractionTests/excerptRevealKeepsMovingThroughRewriteAndWidthChanges()": {
        "group": "native-capture", "check": "tag-glass-captures", "marker": "EXCERPT_INK_MOTION_CONFIRMED",
    },
    "MokuseiSettingsIntegrationTests.NativeOverviewDecorationCaptureTests/nativeCloudAndScanMoveInComposedOverview()": {
        "group": "native-capture", "check": "tag-glass-captures", "marker": "NATIVE_OVERVIEW_DECORATION_MOTION_CONFIRMED",
    },
    "MokuseiSettingsIntegrationTests.NativeReadingPagePresentationTests/retainedOverviewReturnsWithLatestContent()": {
        "group": "native-capture", "check": "tag-glass-captures", "marker": "OVERVIEW_RETAINED_RETURN_CONFIRMED",
    },
    "MokuseiSettingsIntegrationTests.NativeMokuLandingTests/fullWorkspaceSearchMorphKeepsTextAndCaretCentered()": {
        "group": "native-controls", "check": "isolated-input", "marker": "SEARCH_CARET_GEOMETRY_CONFIRMED",
    },
}


def ordinary_filter(suites):
    """Retain SwiftPM's suite selection, including parameterized methods."""
    return "^(?:" + "|".join(re.escape(suite) for suite in suites) + ")/"


def native_filter():
    """Match declared IDs and Swift Testing's runtime source-location suffixes."""
    # Swift Testing lists a unique method without its source location, but its
    # runtime Test.ID.description appends /file:line:column. A trailing $ alone
    # misses that ID. A separate --skip also prevents an included ancestor suite
    # from restoring this method through Swift Testing's recursive selection.
    return "^(?:" + "|".join(re.escape(name) for name in NATIVE_METHOD_OWNERS) + ")(?:/|$)"

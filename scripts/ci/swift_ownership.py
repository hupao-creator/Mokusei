"""Discovered Swift methods executed only by a mandatory native replay."""
import re

NATIVE_METHOD_OWNERS = {
    "MokuseiSettingsIntegrationTests.SwiftUIOverviewInteractionTests/titleReversalAndVisibilityCancellationSettlePixels()": {
        "group": "native", "check": "tag-glass-captures", "marker": "TITLE_INCOMING_MOTION_CONFIRMED",
    },
}


def native_filter():
    """Match declared IDs and Swift Testing's runtime source-location suffixes."""
    # Swift Testing lists a unique method without its source location, but its
    # runtime Test.ID.description appends /file:line:column. A trailing $ alone
    # misses that ID. Run the whole ordinary suite with this exclusion and no
    # positive ancestor filter that could restore the native-owned method.
    return "^(?:" + "|".join(re.escape(name) for name in NATIVE_METHOD_OWNERS) + ")(?:/|$)"

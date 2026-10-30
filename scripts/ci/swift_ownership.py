"""Discovered Swift methods executed only by a mandatory native replay."""
import re

NATIVE_METHOD_OWNERS = {
    "MokuseiSettingsIntegrationTests.SwiftUIOverviewInteractionTests/titleReversalAndVisibilityCancellationSettlePixels()": {
        "group": "native-capture", "check": "tag-glass-captures", "marker": "TITLE_INCOMING_MOTION_CONFIRMED",
    },
}


def ordinary_filter(suites=None):
    """Preserve suite selection while excluding only complete owned identities."""
    excluded = "|".join(re.escape(name) for name in NATIVE_METHOD_OWNERS)
    selection = "" if suites is None else "(?:" + "|".join(re.escape(suite) for suite in suites) + ")/"
    return "^(?!(?:" + excluded + ")$)" + selection

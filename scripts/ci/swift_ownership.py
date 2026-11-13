"""Swift methods executed only by a mandatory native replay."""
import re

NATIVE_METHOD_OWNERS = {
    "MokuseiSettingsIntegrationTests.NativeThreadSendFeedbackTests/completedSendAllowsClickingAndTypingIntoTheResidentComposer(exactExecution:cancelHandoff:)": {
        "group": "native", "check": "thread-send-feedback", "marker": "THREAD_SEND_COMPOSER_REFOCUS_CONFIRMED",
    },
    "MokuseiSettingsIntegrationTests.NativeThreadSendFeedbackTests/sidecardApertureTravelsBetweenItsActualLauncherAndPanel(width:)": {
        "group": "native", "check": "thread-send-feedback", "marker": "THREAD_SIDECARD_ORIGIN_GEOMETRY_CONFIRMED",
    },
    "MokuseiSettingsIntegrationTests.NativeThreadSendFeedbackTests/rightSidecardButtonsToggleRetainedPluginsWithoutCloseIcons(card:)": {
        "group": "native", "check": "thread-send-feedback", "marker": "THREAD_SIDECARD_TOGGLES_CONFIRMED",
    },
    "MokuseiSettingsIntegrationTests.NativeThreadSendFeedbackTests/mountedProductionReadersHandOffAfterContentAdmission(width:mode:)": {
        "group": "native", "check": "thread-send-feedback", "marker": "THREAD_SEND_NATIVE_HANDOFF_CONFIRMED",
    },
    "MokuseiSettingsIntegrationTests.NativeThreadSendFeedbackTests/productionDockFoldsOnSendAndOnlyRestoresAFailedCurrentDraft(outcome:)": {
        "group": "native", "check": "thread-send-feedback", "marker": "THREAD_SEND_DOCK_FEEDBACK_CONFIRMED",
    },
    "MokuseiSettingsIntegrationTests.NativeMokuExecutionLinkTests/noteCapsulesWrapCopyAndRefreshTheirHarnessWithoutChangingTheNote(harness:)": {
        "group": "native", "check": "moku-execution-links", "marker": "MOKU_NOTE_EXECUTION_CAPSULES_CONFIRMED",
    },
    "MokuseiGitIntegrationTests.GitThreadExtensionTests/sharedTokenFlipAnimationWorksAtSummaryAndOriginalSizes()": {
        "group": "native", "check": "rolling-numbers", "marker": "GIT_TOKEN_FLIP_FRAMES_CONFIRMED",
    },
    "MokuseiGitIntegrationTests.RollingNumberCellTests/projectedUsageUpdatesKeepTheirAnimation()": {
        "group": "native", "check": "rolling-numbers", "marker": "PROJECTED_USAGE_FLIP_FRAMES_CONFIRMED",
    },
    "MokuseiSettingsIntegrationTests.NativeOnboardingTagSurfaceTests/productionAnimationMountsWithoutAnOpaqueFirstFrame()": {
        "group": "native", "check": "tag-glass-captures", "marker": "TAG_ONBOARDING_FIRST_FRAME_CONFIRMED",
    },
    "MokuseiSettingsIntegrationTests.SwiftUIOverviewInteractionTests/titleReversalAndVisibilityCancellationSettlePixels()": {
        "group": "native", "check": "tag-glass-captures", "marker": "TITLE_INCOMING_MOTION_CONFIRMED",
    },
    "MokuseiSettingsIntegrationTests.SwiftUIOverviewInteractionTests/excerptRevealKeepsMovingThroughRewriteAndWidthChanges()": {
        "group": "native", "check": "tag-glass-captures", "marker": "EXCERPT_INK_MOTION_CONFIRMED",
    },
    "MokuseiSettingsIntegrationTests.NativeOverviewDecorationCaptureTests/nativeCloudAndScanMoveInComposedOverview()": {
        "group": "native", "check": "tag-glass-captures", "marker": "NATIVE_OVERVIEW_DECORATION_MOTION_CONFIRMED",
    },
}


# These cases compile the production App entry point into a separate executable;
# they cannot belong to SwiftPM's imported-library test inventory. Their outcomes
# still require the same single owner receipt, passing result and marker.
STANDALONE_METHOD_OWNERS = {
    "ReadingPresentationReplay.NativeWorkspaceLifecycleReplay/reloadWaitsForScopedCleanupBeforeReplacingPresentation()": {
        "group": "native", "check": "workspace-lifecycle", "marker": "WORKSPACE_RELOAD_RESOURCE_DRAIN_CONFIRMED",
    },
    "ReadingPresentationReplay.NativeWorkspaceLifecycleReplay/quitRevokesReloadUntilRejectedSaveRestoresWorkspace()": {
        "group": "native", "check": "workspace-lifecycle", "marker": "WORKSPACE_QUIT_REVOKES_RELOAD_PUBLICATION_CONFIRMED",
    },
    "ReadingPresentationReplay.NativeWorkspaceLifecycleReplay/rejectedQuitCannotLetAnOldReloadClearItsSuccessor()": {
        "group": "native", "check": "workspace-lifecycle", "marker": "WORKSPACE_RELOAD_SUCCESSOR_IDENTITY_CONFIRMED",
    },
}


def native_filter():
    """Match declared IDs and Swift Testing's runtime source-location suffixes."""
    # Swift Testing lists a unique method without its source location, but its
    # runtime Test.ID.description appends /file:line:column. A trailing $ alone
    # misses that ID. Run the whole ordinary suite with this exclusion and no
    # positive ancestor filter that could restore the native-owned method.
    return "^(?:" + "|".join(re.escape(name) for name in NATIVE_METHOD_OWNERS) + ")(?:/|$)"

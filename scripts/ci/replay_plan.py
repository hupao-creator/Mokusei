"""Shared command inventory for replay execution and complete-evidence auditing."""
import sys


def fixture_environment(output):
    return {
        "MOKUSEI_INITIAL_RESPONSE_FIXTURES": str(output / "initial-response.json"),
        "MOKU_STATUS_NATIVE_FIXTURE": str(output / "moku-status.json"),
        "MOKU_TIMER_NATIVE_FIXTURE": str(output / "moku-timer.json"),
        "MOKUSEI_VOICE_EVENT_EXPORT": str(output / "voice-events.json"),
        "MOKUSEI_CONVERSATION_CONTRACT_EXPORT": str(output / "conversation.json"),
        "MOKUSEI_HARNESS_FORM_FIXTURE": str(output / "harness-forms.json"),
    }


def replay_groups(go_executable, output):
    go = [go_executable, "run", "-race"]
    fixtures = fixture_environment(output)
    return {
        "runtime": [(name, go + ["./tools/verification/" + name]) for name in [
            "transport", "runtime-concurrency", "storage-workspaces", "command-boundaries",
            "applicationhost", "settings-shell", "thread-metadata", "thread-search", "git", "attachment-lifecycle",
        ]] + [("content-publication", [go_executable, "test", "-race", "./internal/platform/transport",
                                       "-run", "^$", "-bench", "^Benchmark(Unchanged|Changed)Content$",
                                       "-benchtime", "3x"])],
        "adapters": [(name.replace("/", "-"), go + ["./tools/verification/" + name]) for name in [
            "claude", "codex", "opencode", "harness-install", "console-oauth", "artificialanalysis",
            "artificialanalysis/lifecycle", "maintenance", "thread-detail-performance",
        ]] + [("pi-read-guard", [sys.executable, "tools/verification/pi/read-guard.py"])],
        "fixtures": [
            ("initial-response", go + ["./tools/verification/initial-response", "-output", fixtures["MOKUSEI_INITIAL_RESPONSE_FIXTURES"]]),
            ("moku", go + ["./tools/verification/moku"]),
            ("voice", go + ["./tools/verification/codex", "-voice-only"]),
            ("conversation", [go_executable, "test", "-count=1", "./internal/hosts/applicationhost",
                              "-run", "^TestConversationProjectionCarriesCurrentSemanticDecoration$"]),
            ("harness-forms", go + ["./tools/verification/opencode/cases/renderer", "-forms-output", fixtures["MOKUSEI_HARNESS_FORM_FIXTURE"]]),
        ],
        "interop": [
            ("swift-deltas", go + ["./tools/verification/transport", "-swift-deltas"]),
            ("swift-files", go + ["./tools/verification/transport", "-swift-files"]),
            ("swift-settings", go + ["./tools/verification/transport", "-swift-settings-capacity"]),
            ("runtime-voice", go + ["./tools/verification/runtime", "-swift-voice"]),
            ("runtime-shutdown", go + ["./tools/verification/runtime-helpers", "--swift-shutdown",
                                       "--artifacts", str(output / "runtime-shutdown")]),
            ("pi-usage", go + ["./tools/verification/pi", "-swift-usage", "-timeout", "10m"]),
            ("devtools", go + ["./tools/verification/devtools"]),
            ("swift-offline-client", go + ["./tools/verification/devtools", "-swift-offline-client"]),
            ("swift-concurrent-client", go + ["./tools/verification/devtools", "-swift-concurrent-client"]),
            ("headless-lifecycle", go + ["./tools/verification/release-health", "-only", "headless",
                                       "-output", str(output / "health")]),
        ],
        "native": [
            ("runtime-build", [go_executable, "build", "-o", str(output / "mokusei-runtime"), "./cmd/mokusei-runtime"]),
            ("settings", go + ["./tools/verification/settings", "-runtime", str(output / "mokusei-runtime"),
                               "-artifacts", str(output / "settings")]),
            ("note-exposure", go + ["./tools/verification/moku", "-swift-note-exposure"]),
            *[(name, [sys.executable, "tools/verification/reading-presentation/run.py", "--" + name]
                     + (["--native-owned"] if name in {"moku-execution-links", "rolling-numbers"} else []))
              for name in ["browser-dialogs", "application-navigation", "workspace-lifecycle", "moku-execution-links", "rolling-numbers", "tag-glass-captures",
                           "settings-transition", "isolated-input"]],
            ("thread-send-feedback", [sys.executable, "tools/verification/reading-presentation/run.py", "--thread-send-feedback-native"]),
            ("scrollbars", [sys.executable, "tools/verification/scrollbars/run.py"]),
        ],
    }

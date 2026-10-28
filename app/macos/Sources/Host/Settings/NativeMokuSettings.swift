import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

@MainActor struct NativeMokuSettings: View {
    let model: NativeSettingsModel
    let harnesses: [AnyHarnessPlugin]
    let locale: DesktopLocale
    let focusRequest: Int
    let motion: NativeMokuSettingsAnimationState
    let harnessSettings: (NativeHarnessSettingsRequest) -> AnyView
    var controller: MokuCharacterController?
    var onCoordinatorFrame: (CGRect?, Bool) -> Void
    var onCloseRequest: () -> Void
    @State private var presentedInstallations: [String: NativeHarnessInstallation] = [:]
    @State private var coordinatorFrame = CGRect.zero
    @State private var dispatchFrame = CGRect.zero
    @State private var textAreaHeights: [String: CGFloat] = [:]
    @FocusState private var focusedHost: String?

    private var moku: JSONValue { model.draft.value["moku"] ?? .object([:]) }
    private var selectedHost: String? {
        let preference = moku["hostHarnessPreference"]?.stringValue
        return preference == "auto" ? model.activeHostHarnessID : preference
    }
    private var enabledHarnesses: [AnyHarnessPlugin] {
        harnesses.filter { harness in
            let id = harness.descriptor.id.string
            let plugin = model.plugins.first { $0.key == "harness:\(id)" }
            return plugin?.enabled != false && plugin?.unavailableReason == nil
        }
    }
    private var pickable: [AnyHarnessPlugin] {
        enabledHarnesses.filter { harness in
            guard let state = presentedInstallations[harness.descriptor.id.string]?.status else { return false }
            return state == .installed || state == .installing
        }
    }
    private var host: AnyHarnessPlugin? { pickable.first { $0.descriptor.id.string == selectedHost && $0.descriptor.threadCapabilities.canHostMoku } }
    private var targets: [String] { moku["targetHarnessIds"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    private var visibleTargets: [String] { pickable.map { $0.descriptor.id.string }.filter { targets.contains($0) } }
    private var rosterReady: Bool { model.installationLoadState == .loaded }
    private var rosterPending: Bool {
        model.installationLoadState == .notLoaded || model.installationLoadState == .loading
            || (rosterReady && pickable.isEmpty && enabledHarnesses.contains { model.installations[$0.descriptor.id.string]?.status == .checking })
    }
    private var rosterError: String? {
        if case .failed(let message) = model.installationLoadState { return message }
        let errors = enabledHarnesses.compactMap { harness -> String? in
            let id = harness.descriptor.id.string
            guard let installation = model.installations[id], installation.status == .error else { return nil }
            return harness.descriptor.displayName.string + ": " + (installation.message ?? locale.text("检测失败", "Detection failed"))
        }.joined(separator: "\n")
        return errors.isEmpty ? nil : errors
    }
    private var routingEnabled: Bool { if case .string = moku["routingGuidance"] { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsRow(label: locale.text("协调与派发", "Coordination and dispatch"), description: locale.text("上方选择负责协调的 Agent，下方选择它可以派发任务的 Harness。", "Choose the coordinating Agent above and the Harnesses it may dispatch to below."), stacked: true) {
                    if rosterPending {
                        rosterStatus {
                            NativeSettingsNotice(message: locale.text("正在读取 Agent 配置…", "Loading Agent configuration…"),
                                leading: AnyView(ProgressView().controlSize(.small)))
                        }
                    } else if !rosterReady || pickable.isEmpty {
                        rosterStatus {
                            SettingsNotice(rosterError == nil
                                ? locale.text("暂无可用的 Agent。请在「通用」中安装本地 Agent 后重试。", "No Agents are available. Install a local Agent in General, then retry.")
                                : locale.text("无法读取 Agent 配置，请重试。", "Unable to load Agent configuration. Please retry."), error: rosterError != nil) { retryDiscovery }
                            if let rosterError { SettingsNotice(rosterError, error: true) }
                        }
                    } else {
                        dispatchMap
                        if let rosterError {
                            SettingsNotice(locale.text("部分 Agent 检测失败：", "Some Agents could not be detected: ") + rosterError, error: true) { retryDiscovery }
                        }
                    }
                }
            }
            if model.mokuRunning {
                SettingsNotice(locale.text("当前运行使用启动时的配置，修改将在下次运行生效。", "The current run uses the configuration captured at startup. Changes take effect on the next run."))
            }
            if rosterReady, !rosterPending, let host {
                harnessSettings(NativeHarnessSettingsRequest(harnessID: host.descriptor.id, section: .thread,
                    executionSnapshot: true, scopeID: nil, refreshSequence: 0,
                    savedValue: model.savedSettings["moku"]?["executionHarnesses"]?[host.descriptor.id.string] ?? .null,
                    value: model.harnessValueBinding(host.descriptor.id.string, execution: true)))
                    .environment(\.nativeSettingsInteractionScope, "moku." + host.descriptor.id.string)
            } else if rosterReady, !rosterPending, selectedHost.flatMap({ model.installations[$0]?.status }) == .checking {
                NativeSettingsNotice(message: locale.text("正在读取所选 Agent 配置…", "Loading the selected Agent configuration…"))
            } else if rosterReady, !rosterPending, !pickable.isEmpty,
                      selectedHost.flatMap({ model.installations[$0]?.status }) != .error {
                SettingsNotice(selectedHost == nil
                    ? locale.text("当前值不可用，请选择", "The current value is unavailable. Please choose one.")
                    : locale.text("当前 Moku provider 值不可用，请重新选择。", "The selected Moku provider is unavailable. Please choose another."), error: selectedHost != nil)
            }
            // These are later direct .sf-group siblings of the dispatch group.
            // Harness-owned groups are nested in each plugin's own wrapper and
            // inherit only the 8-point bottom margin, never this top adjustment.
            SettingsGroup {
                SettingsRow(label: locale.text("自定义模型路由指导", "Custom model routing guidance"), inlineControl: true) {
                    NativeSettingsToggle(value: Binding(get: { routingEnabled }, set: { changeMoku("routingGuidance", $0 ? .text("") : .null) }))
                        .nativeSettingsControl("routingEnabled")
                        .accessibilityLabel(locale.text("自定义模型路由指导", "Custom model routing guidance"))
                }
                if routingEnabled {
                    SettingsRow(label: locale.text("Moku 模型路由指导", "Moku model routing guidance"), error: model.draft.validationError("routingGuidance", locale: locale), stacked: true) {
                        textArea(field: "routingGuidance", label: locale.text("输入 Moku 选择模型时应遵循的规则", "Enter the rules Moku should follow when selecting models"), height: 112)
                    }.id("routingGuidance")
                }
            }.padding(.top, -10)
        }
        .environment(\.nativeSettingsGroupBottomSpacing, 8)
        .onAppear {
            presentedInstallations = model.installations
            motion.configure(hostID: host?.descriptor.id.string, inFlight: model.mokuInFlight)
            reportCoordinator()
        }
        .onChange(of: model.installations) { _, value in
            // Flight freezes an existing seat, never the initial empty/error
            // roster: discovery may finish after the character has departed.
            if !model.mokuInFlight || !presentedInstallations.values.contains(where: { $0.status == .installed }) {
                presentedInstallations = value
            }
        }
        .onChange(of: model.mokuInFlight) { _, inFlight in
            if !inFlight { presentedInstallations = model.installations }
            motion.configure(hostID: host?.descriptor.id.string, inFlight: inFlight)
        }
        .onChange(of: rosterPending) { _, _ in reportCoordinator() }
        .onChange(of: host?.descriptor.id) { _, new in
            motion.configure(hostID: new?.string, inFlight: model.mokuInFlight)
            if new == nil { onCoordinatorFrame(nil, true) }
        }
    }

    private func rosterStatus<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NativePalette.settings.inputBorder.swiftUI))
    }

    private var retryDiscovery: some View {
        Button(locale.text("重试", "Retry")) { Task { await model.refreshInstallations() } }
            .buttonStyle(.bordered).disabled(model.probing || !model.runtimeAvailable)
            .nativeSettingsAction("retryDiscovery", label: "Retry Agent discovery") { Task { await model.refreshInstallations() } }
    }

    private var dispatchMap: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 38)
            let count = max(1, pickable.count)
            let hostIndex = pickable.firstIndex { $0.descriptor.id == host?.descriptor.id }
            let sourceX = hostIndex.map { 19 + available * (CGFloat($0) + 0.5) / CGFloat(count) }
            let source = sourceX.map { CGPoint(x: $0, y: 111.8) }
            TimelineView(.animation(minimumInterval: NativeFrameRate.interval)) { _ in
                let now = NativeMokuSettingsAnimationState.now
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        if let point = motion.dispatchPosition(at: now) ?? source {
                            for (index, harness) in pickable.enumerated() where targets.contains(harness.descriptor.id.string) {
                                let destination = CGPoint(x: targetX(index, width: geometry.size.width), y: 179)
                                let bend = (destination.y - point.y) * 0.55
                                var path = Path(); path.move(to: point)
                                path.addCurve(to: destination, control1: CGPoint(x: point.x, y: point.y + bend),
                                              control2: CGPoint(x: destination.x, y: destination.y - bend))
                                context.stroke(path, with: .color(NativePalette.settings.accent.swiftUI.opacity(0.7)),
                                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 7],
                                                       dashPhase: NativeMokuSettingsMotion.dispatchDashPhase(nowMilliseconds: now)))
                            }
                        }
                    }.allowsHitTesting(false)
                    ForEach(Array(pickable.enumerated()), id: \.element.descriptor.id) { index, harness in
                        let id = harness.descriptor.id.string
                        let x = 19 + available * (CGFloat(index) + 0.5) / CGFloat(count)
                        let selected = host?.descriptor.id == harness.descriptor.id
                        let supported = harness.descriptor.threadCapabilities.canHostMoku
                        NativeHarnessSettingsIcon(harness: harness, state: model.installationState(id),
                                                  hostSlot: true, hideLogo: selected) { selectHost(harness) }
                            .nativeSettingsAction("host." + id, label: harness.descriptor.displayName.string, selected: selected) { selectHost(harness) }
                            .scaleEffect(selected ? 1.7 : 0.88).position(x: x, y: 71)
                            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.48), value: selected)
                            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.48), value: x)
                            .disabled(!supported)
                            .focusable(supported && (selected || (host == nil && pickable.first(where: { $0.descriptor.threadCapabilities.canHostMoku })?.descriptor.id == harness.descriptor.id)))
                            .focused($focusedHost, equals: id)
                            .accessibilityLabel(harness.descriptor.displayName.string + (supported ? " · " + hostStatusText(id) : locale.text("（不支持 Moku Host）", " (does not support Moku Host)")))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end]) { event in
                                navigateHost(current: id, key: event.key); return .handled
                            }
                        let feedback = feedbackSample(target: id, now: now)
                        NativeHarnessSettingsIcon(harness: harness, state: model.installationState(id),
                                                  logoTransform: feedback?.target ?? .init(),
                                                  logoOpacity: feedback?.targetOpacity ?? 1, checked: targets.contains(id)) { toggleTarget(id) }
                            .nativeSettingsAction("target." + id, label: harness.descriptor.displayName.string, selected: targets.contains(id)) { toggleTarget(id) }
                            .overlay(alignment: .bottom) {
                                Capsule().fill(NativePalette.settings.accent.swiftUI).frame(width: 13, height: 2)
                                    .scaleEffect(x: targets.contains(id) ? 1 : 0.5, y: 1)
                                    .opacity(targets.contains(id) ? 0.6 : 0).offset(y: -2)
                                    .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.18), value: targets.contains(id))
                            }.position(x: targetX(index, width: geometry.size.width), y: 203)
                            .disabled(targets.contains(id) && visibleTargets.count == 1)
                            .help(targets.contains(id) && visibleTargets.count == 1 ? locale.text("至少保留一个可派发的 provider", "Keep at least one dispatch target") : "")
                            .accessibilityLabel(harness.descriptor.displayName.string + " · " + hostStatusText(id))
                            .accessibilityAddTraits(targets.contains(id) ? .isSelected : [])
                    }
                    if let host, let sourceX { coordinator(host, sourceX: sourceX, now: now) }
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
            .onChange(of: source, initial: true) { _, point in motion.configureDispatch(source: point, hasTargets: !visibleTargets.isEmpty) }
            .onChange(of: visibleTargets) { _, _ in motion.configureDispatch(source: source, hasTargets: !visibleTargets.isEmpty) }
            .onAppear { dispatchFrame = geometry.frame(in: .global) }
            .onChange(of: geometry.frame(in: .global)) { _, frame in dispatchFrame = frame }
        }.frame(height: 246).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NativePalette.settings.inputBorder.swiftUI))
    }

    private func coordinator(_ host: AnyHarnessPlugin, sourceX: CGFloat, now: Double) -> some View {
        let handoff = motion.handoff.map { NativeMokuSettingsMotion.handoff(elapsedMilliseconds: now - $0.startedAt, direction: $0.direction) }
        let feedback = motion.feedback.map { NativeMokuSettingsMotion.feedback(enabled: $0.request.enabled, gazeX: $0.request.gazeX,
                                                                              elapsedMilliseconds: now - $0.startedAt) }
        let idle = motion.idleStartedAt.map { NativeMokuSettingsMotion.idle(elapsedMilliseconds: now - $0) }
        let previous = motion.handoff?.previousID.flatMap { id in harnesses.first { $0.descriptor.id.string == id } }
        return ZStack {
            MokuCharacterView(mode: .idle, motionActive: !model.mokuInFlight, scope: "settings", identity: "moku", controller: controller,
                              usesResident: false, eyeMotion: motion.handoff?.eyeMotion ?? motion.feedback?.eyeMotion)
                .frame(width: 122.4, height: 122.4)
            NativeMokuEngineHandoff(current: host, previous: previous, elapsedMilliseconds: motion.handoff.map { now - $0.startedAt } ?? 1050)
                .scaleEffect(feedback?.engine.scale ?? 1).opacity(feedback?.engine.opacity ?? 1)
                .scaleEffect(1.7).offset(y: 18.7)
        }.frame(width: 81.6, height: 81.6)
            .modifier(NativeMokuSettingsTransform(pose: feedback?.body ?? idle ?? .init()))
            .modifier(NativeMokuSettingsTransform(pose: handoff?.receipt ?? .init()))
            .offset(y: (handoff?.approachY ?? 0) * 1.7)
            .opacity(model.mokuInFlight ? 0 : 1)
            .background(GeometryReader { seat in
                Color.clear.onAppear { coordinatorFrame = seat.frame(in: .global); reportCoordinator() }
                    .onChange(of: seat.frame(in: .global)) { _, rect in coordinatorFrame = rect; reportCoordinator() }
            }).position(x: sourceX, y: 71).allowsHitTesting(false)
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.72), value: sourceX)
    }

    private func feedbackSample(target: String, now: Double) -> NativeMokuSettingsMotion.Feedback? {
        guard let clip = motion.feedback, clip.request.targetID == target else { return nil }
        return NativeMokuSettingsMotion.feedback(enabled: clip.request.enabled, gazeX: clip.request.gazeX,
                                                 elapsedMilliseconds: now - clip.startedAt)
    }
    private func targetX(_ index: Int, width: CGFloat) -> CGFloat {
        let count = max(1, pickable.count)
        return 43 + (count == 1 ? 0 : max(0, width - 86) * CGFloat(index) / CGFloat(count - 1))
    }

    private func textArea(field: String, label: String, height: CGFloat) -> some View {
        let error = model.draft.validationError(field, locale: locale)
        return VStack(alignment: .leading, spacing: 6) {
            SettingsTextArea(text: Binding(get: { moku[field]?.stringValue ?? "" }, set: { text in
                changeMoku(field, .text(text), textEdit: true)
            }), accessibilityLabel: label, placeholder: label, invalid: error != nil,
               focusRequest: model.draft.firstInvalidField == field ? focusRequest : 0,
               onEscape: onCloseRequest)
                .nativeSettingsControl(field)
                .frame(height: textAreaHeights[field] ?? height)
            Stepper(locale.text("编辑器高度", "Editor height"), value: Binding(
                get: { textAreaHeights[field] ?? height }, set: { textAreaHeights[field] = $0 }),
                in: 112...CGFloat.greatestFiniteMagnitude, step: 28)
                .controlSize(.small).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func changeMoku(_ field: String, _ value: JSONValue?, textEdit: Bool = false) {
        model.draft.change(settingsReplacing(model.draft.value, path: ["moku", field], value: value), textEdit: textEdit)
    }
    private func hostStatusText(_ id: String) -> String {
        switch model.installationState(id) {
        case .checking: locale.text("正在检测…", "Checking…")
        case .installed: locale.text("已安装", "Installed")
        case .missing: locale.text("未安装", "Not installed")
        case .installing: locale.text("正在安装…", "Installing…")
        case .error: locale.text("检测失败", "Detection failed")
        }
    }
    private func selectHost(_ harness: AnyHarnessPlugin) {
        guard harness.descriptor.threadCapabilities.canHostMoku, host?.descriptor.id != harness.descriptor.id else { return }
        if !coordinatorFrame.isEmpty, let index = pickable.firstIndex(where: { $0.descriptor.id == harness.descriptor.id }) {
            let destination = dispatchFrame.minX + 19 + max(0, dispatchFrame.width - 38) * (CGFloat(index) + 0.5) / CGFloat(max(1, pickable.count))
            motion.beginHandoff(to: harness.descriptor.id.string, direction: destination - coordinatorFrame.midX)
        }
        changeMoku("hostHarnessPreference", .string(harness.descriptor.id))
    }
    private func toggleTarget(_ id: String) {
        let selected = targets.contains(id)
        guard !selected || visibleTargets.count > 1 else { return }
        let index = pickable.firstIndex { $0.descriptor.id.string == id }
        let gaze = index.map { (dispatchFrame.minX + targetX($0, width: dispatchFrame.width) - coordinatorFrame.midX) / 4 } ?? 0
        motion.requestFeedback(targetID: id, enabled: !selected, gazeX: coordinatorFrame.isEmpty ? 0 : gaze)
        changeMoku("targetHarnessIds", .array((selected ? targets.filter { $0 != id } : targets + [id]).map(JSONValue.text)))
    }
    private func reportCoordinator() {
        onCoordinatorFrame(!rosterReady || host == nil || coordinatorFrame.isEmpty ? nil : coordinatorFrame, rosterPending)
    }
    private func navigateHost(current: String, key: KeyEquivalent) {
        let supported = pickable.filter { $0.descriptor.threadCapabilities.canHostMoku }
        guard !supported.isEmpty else { return }
        let index = supported.firstIndex { $0.descriptor.id.string == current } ?? 0
        let next = key == .home ? 0 : key == .end ? supported.count - 1 : (index + (key == .leftArrow || key == .upArrow ? -1 : 1) + supported.count) % supported.count
        selectHost(supported[next]); focusedHost = supported[next].descriptor.id.string
    }
}

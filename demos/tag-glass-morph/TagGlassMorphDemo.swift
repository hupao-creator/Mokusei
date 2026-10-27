import Combine
import SwiftUI

/// An isolated visual experiment, deliberately not referenced by MokuseiUI.
@available(macOS 26.0, *)
struct TagGlassMorphDemo: View {
    @State private var visibleIDs = ["directory", "design"]
    @State private var selectedID = "all"
    @State private var dark = true
    @State private var slow = false
    @State private var animated = true
    @State private var playing = false
    @State private var playbackIndex = 0
    @State private var reduceTransparency = false
    @State private var countOffset = 0
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency

    private let catalog: [MorphTag] = [
        .init(id: "directory", title: "Mokusei", count: 12, directory: true),
        .init(id: "design", title: "界面设计", count: 4),
        .init(id: "performance", title: "性能优化", count: 3),
        .init(id: "research", title: "代码调研", count: 6),
        .init(id: "voice", title: "语音交互", count: 2),
        .init(id: "long", title: "一个较长的工作目录名称", count: 24, directory: true)
    ]
    private var tags: [MorphTag] {
        visibleIDs.compactMap { id in catalog.first { $0.id == id } }
            .map { tag in var tag = tag; tag.count += countOffset; return tag }
    }
    private var motionDisabled: Bool { !animated }
    private var opaque: Bool { systemReduceTransparency || reduceTransparency }
    private var duration: Double { slow ? 1.6 : 0.48 }
    private var animation: Animation? {
        motionDisabled ? nil : .smooth(duration: duration, extraBounce: 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Tag · Glass Morph").font(.system(size: 26, weight: .semibold))
                    Text("标签数量变化 · 独立原生预览")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("深色", isOn: $dark).toggleStyle(.switch).controlSize(.small)
            }
            .padding(.bottom, 30)

            HStack(spacing: 10) {
                Button(playing ? "停止播放" : "播放完整演示") {
                    if !playing { withAnimation(animation) { setTags(2) }; playbackIndex = 0 }
                    playing.toggle()
                }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("morph-play")
                Button("增加一个") { manual { addTag() } }
                    .disabled(visibleIDs.count == catalog.count)
                Button("删除选中 / 末尾") { manual { removeTag() } }
                    .disabled(visibleIDs.isEmpty)
                Button("批量 2 ⇄ 6") { manual { setTags(visibleIDs.count > 2 ? 2 : 6) } }
                Button("清空") { manual { setTags(0) } }.disabled(visibleIDs.isEmpty)
                Button("重置") { manual { countOffset = 0; setTags(2); selectedID = "all" } }
            }
            .controlSize(.large)
            .padding(.bottom, 12)

            HStack(spacing: 22) {
                Toggle("启用动画", isOn: $animated)
                Toggle("慢速 · 1.6 秒", isOn: $slow)
                Button("数字 4 ⇄ 100") { manual { countOffset = countOffset == 0 ? 96 : 0 } }
                Spacer()
                Text("\(visibleIDs.count) 个标签").monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityIdentifier("morph-count")
            }
            .font(.system(size: 12)).toggleStyle(.checkbox)
            .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("放大观察", detail: "Regular glass · 48 pt · 间距 / 融合距离 16 pt")
                MorphTagRow(tags: tags, selectedID: $selectedID, large: true, opaque: opaque)
                    .frame(height: 100)
                Divider().padding(.vertical, 18)
                sectionLabel("Overview 尺寸", detail: "Clear glass · 32 pt · 间距 / 融合距离 4 pt")
                MorphTagRow(tags: tags, selectedID: $selectedID, large: false, opaque: opaque)
                    .frame(height: 76)
            }
            .padding(.horizontal, 24).padding(.vertical, 24)
            .background {
                // Ordinary colored content behind the glass; no nested glass sampler.
                ZStack {
                    Color(white: dark ? 0.13 : 0.93)
                    Ellipse().fill(Color.purple.opacity(dark ? 0.30 : 0.16))
                        .frame(width: 580, height: 260).blur(radius: 90).offset(x: -200, y: -50)
                    Ellipse().fill(Color.blue.opacity(dark ? 0.22 : 0.12))
                        .frame(width: 420, height: 250).blur(radius: 80).offset(x: 260, y: 80)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22))
            }

            HStack(spacing: 18) {
                Toggle("预览降低透明度", isOn: $reduceTransparency)
                Spacer()
                Text("选中：\(catalog.first { $0.id == selectedID }?.title ?? "全部")")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.system(size: 12)).toggleStyle(.checkbox)
            .padding(.top, 22)
            Spacer(minLength: 16)
            Text(motionDisabled ? "动画已关闭；新增和删除立即生效。" : "点击标签后可删除中间项；两行可横向滚动，观察长标签与边缘裁切。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("仅用于评审 · 不读取会话数据 · 尚未接入正式筛选器")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 7)
        }
        .padding(32)
        .frame(minWidth: 900, minHeight: 650)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: dark ? 0.085 : 0.985))
        .environment(\.colorScheme, dark ? .dark : .light)
        .preferredColorScheme(dark ? .dark : .light)
        .overlay {
            if playing {
                MorphPlaybackClock(interval: slow ? 2.7 : 1.4) {
                    let sequence = [2, 3, 4, 2, 6, 0, 2]
                    playbackIndex = (playbackIndex + 1) % sequence.count
                    withAnimation(animation) { setTags(sequence[playbackIndex]) }
                }
                .frame(width: 0, height: 0).accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .onDisappear { playing = false }
    }

    private func sectionLabel(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func manual(_ action: () -> Void) {
        playing = false
        withAnimation(animation, action)
    }
    private func setTags(_ count: Int) {
        visibleIDs = catalog.prefix(count).map(\.id)
        if !visibleIDs.contains(selectedID) { selectedID = "all" }
    }
    private func addTag() {
        guard let next = catalog.first(where: { !visibleIDs.contains($0.id) }) else { return }
        // Restore catalog order after removing and reinserting a middle tag.
        let ids = Set(visibleIDs + [next.id])
        visibleIDs = catalog.filter { ids.contains($0.id) }.map(\.id)
    }
    private func removeTag() {
        guard let id = visibleIDs.contains(selectedID) ? selectedID : visibleIDs.last else { return }
        visibleIDs.removeAll { $0 == id }
        if selectedID == id { selectedID = "all" }
    }
}

private struct MorphTag: Identifiable {
    let id: String
    let title: String
    var count: Int
    var directory = false
}

@available(macOS 26.0, *)
private struct MorphTagRow: View {
    let tags: [MorphTag]
    @Binding var selectedID: String
    let large: Bool
    let opaque: Bool
    @Namespace private var glassNamespace
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollView(.horizontal) {
            // Keep container within the scroll aperture so captured glass labels cannot escape it.
            GlassEffectContainer(spacing: large ? 16 : 4) {
                HStack(spacing: large ? 16 : 4) {
                    tagButton(.init(id: "all", title: "全部", count: 0))
                    ForEach(tags) { tag in tagButton(tag) }
                }
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 8).padding(.vertical, 14)
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(large ? "放大玻璃标签" : "Overview 尺寸标签")
    }

    private func tagButton(_ tag: MorphTag) -> some View {
        let active = selectedID == tag.id
        let ink = scheme == .dark ? Color.white : Color.black
        return Button { selectedID = tag.id } label: {
            HStack(spacing: large ? 8 : 6) {
                if tag.directory {
                    Image(systemName: "folder").font(.system(size: large ? 14 : 11)).opacity(0.72)
                }
                Text(tag.title)
                    .font(.system(size: large ? 15 : 10.5, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                if tag.id != "all" {
                    Text(String(tag.count))
                        .font(.system(size: large ? 11 : 8.5, weight: .bold))
                        .monospacedDigit().frame(minWidth: 6)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(ink.opacity(active ? 0.10 : 0.08), in: Capsule())
                }
            }
            .padding(.horizontal, large ? 17 : 12)
            .frame(height: large ? 48 : 32)
            .frame(maxWidth: large ? 250 : 180)
            .foregroundStyle(ink)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if opaque {
                Capsule().fill(Color(white: scheme == .dark ? (active ? 0.30 : 0.19) : (active ? 0.78 : 0.96)))
            }
        }
        .glassEffect(opaque ? .identity : (large ? Glass.regular : Glass.clear)
            .tint(active ? ink.opacity(contrast == .increased ? 0.28 : 0.16) : nil).interactive(), in: .capsule)
        // Each surface owns a stable ID, never an array position or a random UUID.
        .glassEffectID(tag.id, in: glassNamespace)
        .glassEffectTransition(.matchedGeometry)
        .overlay {
            Capsule().strokeBorder(ink.opacity(active ? 0.44 : 0), lineWidth: 1).allowsHitTesting(false)
        }
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityLabel(tag.id == "all" ? "全部" : "\(tag.title)，\(tag.count) 个会话")
        .accessibilityIdentifier("\(large ? "large" : "compact")-tag-\(tag.id)")
        .help(tag.title)
    }
}

#Preview("Tag Glass Morph · 独立评审") {
    TagGlassMorphDemo().frame(width: 1020, height: 670)
}

/// The publisher exists only while playback is visible; stopping removes its subscription.
private struct MorphPlaybackClock: View {
    let interval: TimeInterval
    var advance: () -> Void
    var body: some View {
        Color.clear.onReceive(Timer.publish(every: interval, on: .main, in: .common).autoconnect()) { _ in
            advance()
        }
    }
}

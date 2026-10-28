import MokuseiPluginUI
import SwiftUI

public enum NativeOverviewTagKind: String, Sendable { case directory, semantic }

public struct NativeOverviewFilter: Identifiable, Equatable, Sendable {
    public var tag: String
    public var displayTag: String
    public var emoji: String?
    public var scope: String
    public var count: Int
    public var aliases: [String]
    public var isDirectory: Bool
    public var selectionKey: String
    /// A directory filter owns the semantic tags of its scope. Inbox tags are
    /// top-level semantic filters and have no directory parent.
    public var children: [NativeOverviewFilter]
    // Membership changes counts and selectionKey, not the identity of this control.
    public var id: String { "\(isDirectory ? "directory" : "semantic"):\(scope):\(Self.key(tag))" }

    public init(tag: String, displayTag: String? = nil, emoji: String? = nil, scope: String = "", count: Int, aliases: [String] = [],
                isDirectory: Bool = false, selectionKey: String = "", children: [NativeOverviewFilter] = []) {
        self.tag = tag; self.displayTag = displayTag ?? tag; self.emoji = emoji
        self.scope = scope; self.count = count; self.aliases = aliases
        self.isDirectory = isDirectory; self.selectionKey = selectionKey; self.children = children
    }

    public func matches(_ selectedTag: String, kind: NativeOverviewTagKind? = nil, scope: String? = nil) -> Bool {
        if let kind, isDirectory != (kind == .directory) { return false }
        if let scope, !scope.isEmpty, self.scope != scope { return false }
        let selected = Self.key(selectedTag)
        return Self.key(tag) == selected || aliases.contains { Self.key($0) == selected }
    }

    private static func key(_ text: String) -> String {
        NativeOverviewSelection.key(text)
    }
}

/// Floating Liquid Glass controls. The host owns collection filtering.
public struct NativeOverviewChrome: View {
    public var filters: [NativeOverviewFilter]
    public var selectedTag: String
    public var selectedScope: String
    public var selectedKind: NativeOverviewTagKind?
    public var cameraManual: Bool
    public var focusFilterRequestKey: Int
    public var onTagChange: (NativeOverviewFilter?) -> Void
    public var onReturnToAuto: (() -> Void)?
    public var onSettings: (() -> Void)?
    /// Bounds use logical points from the top-left of the zoomable client viewport.
    public var onSettingsWithOrigin: ((CGRect) -> Void)?
    public var onSettingsFrameChange: ((CGRect?) -> Void)?
    public var onRestart: (() -> Void)?
    public var onFocusFilterRequestConsumed: (() -> Void)?
    public var clickExclusions: NativeClickExclusions?
    public var interactions: NativeOverviewChromeInteractions?
    public var strings: NativeOverviewChromeStrings
    public var isSearching: Bool
    public var searchQuery: String
    public var searchFocusRequest: Int
    public var onSearchChange: (String) -> Void
    public var onSearchExit: () -> Void
    @FocusState private var focusedTag: String?
    @Namespace private var tagGlass
    @Namespace private var actionGlass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentedFilters: [NativeOverviewFilter]
    @State private var hasPresentedFilters: Bool
    @State private var returnToAutoVisible: Bool
    @State private var settingsAnchor = OverviewSettingsAnchor()
    @State private var measuredAllWidth: CGFloat = 0
    @State private var measuredTagsWidth: CGFloat = 0
    @State private var searchProgress: CGFloat
    @State private var searchMorphVisible: Bool
    @State private var searchCloseTask: Task<Void, Never>?
    @State private var pendingFilterFocus = 0
    @State private var hoveredScope: String?
    @State private var displayedSelection: NativeOverviewTagSelection?
    @State private var latestSelection: NativeOverviewTagSelection?
    @State private var submenuRevision = 0
    @State private var submenuClosing = false
    @State private var retiringMenus: [String: NativeOverviewFilter] = [:]
    @State private var hoverClearTask: Task<Void, Never>?
    @State private var interactionOwner = UUID()
    @Environment(\.overviewSearchMorphDuration) private var searchMorphDuration

    public init(filters: [NativeOverviewFilter], selectedTag: String = "", selectedScope: String = "", selectedKind: NativeOverviewTagKind? = nil,
                cameraManual: Bool = false, focusFilterRequestKey: Int = 0,
                strings: NativeOverviewChromeStrings = .init(),
                isSearching: Bool = false, searchQuery: String = "", searchFocusRequest: Int = 0,
                onSearchChange: @escaping (String) -> Void = { _ in },
                onSearchExit: @escaping () -> Void = {},
                onTagChange: @escaping (NativeOverviewFilter?) -> Void,
                onReturnToAuto: (() -> Void)? = nil,
                onSettings: (() -> Void)? = nil, onRestart: (() -> Void)? = nil,
                onFocusFilterRequestConsumed: (() -> Void)? = nil,
                onSettingsWithOrigin: ((CGRect) -> Void)? = nil,
                onSettingsFrameChange: ((CGRect?) -> Void)? = nil,
                clickExclusions: NativeClickExclusions? = nil, interactions: NativeOverviewChromeInteractions? = nil) {
        self.filters = filters; self.selectedTag = selectedTag; self.selectedScope = selectedScope; self.selectedKind = selectedKind
        let selection = selectedKind.map { NativeOverviewTagSelection(tag: selectedTag, kind: $0, scope: selectedScope) }
        _displayedSelection = State(initialValue: selection)
        _latestSelection = State(initialValue: selection)
        _presentedFilters = State(initialValue: filters)
        _hasPresentedFilters = State(initialValue: !filters.isEmpty)
        self.cameraManual = cameraManual; self.focusFilterRequestKey = focusFilterRequestKey
        _returnToAutoVisible = State(initialValue: cameraManual)
        self.strings = strings; self.onTagChange = onTagChange
        self.onReturnToAuto = onReturnToAuto; self.onSettings = onSettings; self.onRestart = onRestart
        self.onFocusFilterRequestConsumed = onFocusFilterRequestConsumed
        self.clickExclusions = clickExclusions
        self.interactions = interactions
        self.onSettingsWithOrigin = onSettingsWithOrigin; self.onSettingsFrameChange = onSettingsFrameChange
        _searchProgress = State(initialValue: isSearching ? 1 : 0)
        _searchMorphVisible = State(initialValue: isSearching)
        self.isSearching = isSearching; self.searchQuery = searchQuery
        self.searchFocusRequest = searchFocusRequest; self.onSearchChange = onSearchChange; self.onSearchExit = onSearchExit
    }

    public var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width <= 620
            let inset: CGFloat = narrow ? 14 : 18
            // The bar is centered, so reserve the action envelope on both sides.
            // Narrow windows already place actions on a separate row.
            let actionClearance = actionWidth > 0 ? 2 * (actionWidth + 16) : 0
            let maximumFilterWidth = max(0, geometry.size.width - inset * 2 - (narrow ? 0 : actionClearance))
            ZStack(alignment: .top) {
                HStack {
                    Spacer(minLength: 0)
                    actions
                }
                .padding(.horizontal, inset)
                // Retain the scroll/container identities through an empty result so
                // outgoing surfaces can finish, while hiding the empty bar as before.
                filtersBar(maximumWidth: maximumFilterWidth)
                    .frame(width: min(naturalFilterWidth, maximumFilterWidth), height: OverviewTagMetrics.barHeight)
                    .padding(.top, narrow ? OverviewTagMetrics.narrowFilterTop - 10 : 0)
                    .opacity(presentedFilters.isEmpty || searchMorphVisible || isSearching ? 0 : 1)
                    .allowsHitTesting(!presentedFilters.isEmpty && !isSearching && !searchMorphVisible)
                    .disabled(presentedFilters.isEmpty || isSearching || searchMorphVisible)
                    .accessibilityHidden(presentedFilters.isEmpty || isSearching || searchMorphVisible)
            }
            .padding(.top, narrow ? 10 : 16)
            .overlayPreferenceValue(OverviewSearchTagBounds.self) { anchors in
                GeometryReader { reader in
                    if searchMorphVisible || isSearching {
                        let sources = OverviewSearchMorphGeometry.sources(bounds: anchors.mapValues { reader[$0] },
                            filters: presentedFilters, all: strings.all, selectedTag: selectedTag,
                            selectedScope: selectedScope, selectedKind: selectedKind,
                            selectedChildren: Dictionary(uniqueKeysWithValues: presentedFilters.compactMap { filter in
                                displayedChild(of: filter).map { (filter.id, $0) }
                            }))
                        OverviewSearchMorphLayer(progress: searchProgress, searching: isSearching, sources: sources,
                            target: CGRect(x: (geometry.size.width - min(460, maximumFilterWidth)) / 2,
                                           y: narrow ? OverviewTagMetrics.narrowFilterTop : 16,
                                           width: min(460, maximumFilterWidth), height: OverviewTagMetrics.buttonHeight)) { ready in
                                searchContents(focusReady: ready)
                            }
                    }
                }
                .allowsHitTesting(isSearching)
            }
        }
        .frame(height: OverviewTagMetrics.chromeHeight)
        .onChange(of: cameraManual) { _, manual in
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) { returnToAutoVisible = manual }
        }
        .onChange(of: selection) { _, value in
            latestSelection = value
            if hoveredScope == nil && !submenuClosing {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                    displayedSelection = value
                }
            }
        }
        .onChange(of: isSearching) { _, value in transitionSearch(value) }
        .onChange(of: hoveredScope) { _, value in interactions?.setOpenScope(value, owner: interactionOwner) }
        .onDisappear {
            searchCloseTask?.cancel()
            hoverClearTask?.cancel()
            submenuRevision += 1
            hoveredScope = nil
            submenuClosing = false
            retiringMenus = [:]
            displayedSelection = latestSelection
            interactions?.removeChrome(owner: interactionOwner)
        }
        .onChange(of: filters) { _, updated in presentFilters(updated, animated: hasPresentedFilters) }
        .onChange(of: focusFilterRequestKey) { _, request in consumeFocus(request) }
        .onAppear {
            latestSelection = selection
            displayedSelection = selection
            interactions?.installChrome(owner: interactionOwner, openScope: hoveredScope)
            settleSearch()
            presentFilters(filters, animated: false)
            consumeFocus(focusFilterRequestKey)
        }
    }

    private var selection: NativeOverviewTagSelection? {
        selectedKind.map { .init(tag: selectedTag, kind: $0, scope: selectedScope) }
    }

    private func displayedChild(of parent: NativeOverviewFilter) -> NativeOverviewFilter? {
        guard parent.isDirectory, let selection = displayedSelection,
              selection.kind == .semantic, selection.scope == parent.scope else { return nil }
        return parent.children.first { $0.matches(selection.tag, kind: .semantic, scope: selection.scope) }
    }

    private func filterTitle(_ filter: NativeOverviewFilter) -> String {
        displayedChild(of: filter).map { "\(filter.displayTag) / \($0.displayTag)" } ?? filter.displayTag
    }

    private func selectFilter(_ filter: NativeOverviewFilter?) {
        closeChildren()
        onTagChange(filter)
    }

    private func closeChildren() {
        hoverClearTask?.cancel()
        setHoveredScope(nil)
    }

    private var selectedDisplayTag: String {
        (presentedFilters + presentedFilters.flatMap(\.children)).first {
            $0.matches(selectedTag, kind: selectedKind, scope: selectedScope)
        }?.displayTag ?? selectedTag
    }

    private func searchContents(focusReady: Bool) -> some View {
        HStack(spacing: 8) {
            if !selectedTag.isEmpty {
                Text(selectedDisplayTag).font(NativeTypography.inter(size: 10.5, weight: 620))
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 90)
                    .foregroundStyle(.secondary)
                    .help("\(strings.searchIn) \(selectedDisplayTag)")
                Divider().frame(height: 16)
            }
            OverviewThreadSearchField(text: searchQuery,
                placeholder: selectedTag.isEmpty ? strings.search : "",
                focusRequest: focusReady ? searchFocusRequest : 0, onChange: onSearchChange, onExit: onSearchExit)
                .frame(minWidth: 40, maxWidth: .infinity).frame(height: OverviewTagMetrics.buttonHeight)
            Button(action: onSearchExit) {
                Image(systemName: "escape").font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: OverviewTagMetrics.buttonHeight)
            }
            .buttonStyle(.plain).help(strings.closeSearch).accessibilityLabel(strings.closeSearch)
        }
        .padding(.horizontal, OverviewTagMetrics.labelInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strings.search)
    }

    private func transitionSearch(_ searching: Bool) {
        searchCloseTask?.cancel()
        if searching {
            focusedTag = nil
            hoverClearTask?.cancel()
            setHoveredScope(nil)
        }
        searchMorphVisible = true
        withAnimation(.smooth(duration: searchMorphDuration)) {
            searchProgress = searching ? 1 : 0
        }
        guard !searching else { return }
        searchCloseTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(searchMorphDuration)) }
            catch { return }
            guard !Task.isCancelled, !isSearching else { return }
            searchMorphVisible = false
            consumeFocus(pendingFilterFocus)
        }
    }

    private func settleSearch() {
        searchCloseTask?.cancel()
        if isSearching { focusedTag = nil }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            searchProgress = isSearching ? 1 : 0
            searchMorphVisible = isSearching
        }
        if !isSearching { consumeFocus(focusFilterRequestKey) }
    }

    private var actionWidth: CGFloat {
        let count = (onReturnToAuto != nil ? 1 : 0) + (onRestart != nil ? 1 : 0)
            + (onSettings != nil || onSettingsWithOrigin != nil ? 1 : 0)
        return CGFloat(count) * OverviewTagMetrics.actionDiameter + CGFloat(max(0, count - 1)) * OverviewTagMetrics.spacing
    }

    private var actions: some View {
        // Match the layout gap so surfaces morph together during transitions
        // while retaining separate outlines at rest.
        GlassEffectContainer(spacing: OverviewTagMetrics.spacing) {
            HStack(spacing: OverviewTagMetrics.spacing) {
                if returnToAutoVisible, let onReturnToAuto {
                    iconButton("Shrink", size: 15, title: strings.returnToAuto, action: onReturnToAuto)
                        .background {
                            if let clickExclusions {
                                NativeClickExclusionRegion(exclusions: clickExclusions)
                            }
                        }
                }
                if let onRestart { iconButton("RotateCcw", size: 15, title: strings.restart, action: onRestart) }
                if onSettings != nil || onSettingsWithOrigin != nil {
                    iconButton("Settings", size: 15, title: strings.settings,
                               settingsAnchor: settingsAnchor, onSettingsFrameChange: onSettingsFrameChange) {
                        if let rect = settingsAnchor.frame, let onSettingsWithOrigin { onSettingsWithOrigin(rect) }
                        else { onSettings?() }
                    }
                }
            }
            // Reserve the conditional slot without covering the tag glass.
            .frame(width: actionWidth, alignment: .trailing)
        }
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .modifier(OverviewToolbarEntry())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strings.actions)
        .overviewSearchAnchor("__actions__")
    }

    private func filtersBar(maximumWidth: CGFloat) -> some View {
        filterButtons(maximumWidth: maximumWidth)
            .overviewSearchAnchor("__bar__")
            .clipShape(Capsule())
            .backgroundPreferenceValue(OverviewSearchTagBounds.self) { anchors in
                GeometryReader { reader in
                    if let viewport = anchors["__scroll__"] {
                        ForEach(presentedFilters.filter(\.isDirectory)) { parent in
                            if let anchor = anchors[parent.id] {
                                let source = reader[anchor]
                                let visible = source.intersection(reader[viewport])
                                if !visible.isNull, visible.width > 0 {
                                    // Only geometry crosses the scroll boundary. Capturing the
                                    // scrolling labels in this container would bypass its clip.
                                    OverviewDirectoryGlassGroup(parent: parent, source: source,
                                        visible: visible, barWidth: reader.size.width,
                                        active: isActive(parent)) { namespace in
                                            revealedTagButtons(for: parent, namespace: namespace,
                                                source: visible, barWidth: reader.size.width, maximumWidth: maximumWidth)
                                        }
                                        .transition(reduceMotion ? .identity : .opacity)
                                        .modifier(NativeOverviewDirectoryRegistration(registry: interactions, root: interactionOwner, filter: parent,
                                            enabled: !isSearching && !searchMorphVisible && parent.children.contains { $0.count > 0 },
                                            open: { revealChildren(of: parent) }, close: closeChildren,
                                            select: { id in
                                                if let child = parent.children.first(where: { $0.id == id }) { selectChild(child, of: parent) }
                                            }))
                                }
                            }
                        }
                    }
                }
            }
            .modifier(OverviewToolbarEntry())
            .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(strings.filter)
    }

    @ViewBuilder
    private func revealedTagButtons(for parent: NativeOverviewFilter, namespace: Namespace.ID, source: CGRect, barWidth: CGFloat, maximumWidth: CGFloat) -> some View {
        let menu = retiringMenus[parent.scope] ?? parent
        let active = hoveredScope == parent.scope && !isSearching && !searchMorphVisible
        ZStack {
            if (active || retiringMenus[parent.scope] != nil), menu.children.contains(where: { $0.count > 0 }) {
                OverviewTagMenuViewport(maximumWidth: maximumWidth, active: active, source: source, barWidth: barWidth) { progress, target, widths in
                    HStack(spacing: OverviewTagMetrics.submenuSpacing) {
                        ForEach(menu.children.filter { $0.count > 0 }) { child in
                            let current = parent.children.contains { $0.id == child.id && $0.count > 0 }
                            let childProgress = current ? progress : 0
                            Button {
                                selectChild(child, of: parent)
                            } label: {
                                HStack(spacing: OverviewTagMetrics.chipContentSpacing) {
                                    Text(child.displayTag)
                                        .font(NativeTypography.inter(size: OverviewTagMetrics.chipFont, weight: 620))
                                        .lineLimit(1)
                                        .contentTransition(.opacity)
                                    Text(String(child.count))
                                        .font(NativeTypography.inter(size: OverviewTagMetrics.countFont, weight: 680))
                                        .frame(minWidth: OverviewTagMetrics.countMinWidth)
                                        .padding(.horizontal, OverviewTagMetrics.countHorizontalInset)
                                        .padding(.vertical, OverviewTagMetrics.countVerticalInset)
                                        .background(.foreground.opacity(0.08), in: Capsule())
                                }
                                .padding(.horizontal, OverviewTagMetrics.chipLabelInset)
                                .frame(height: OverviewTagMetrics.chipHeight)
                                .frame(maxWidth: maximumWidth)
                                .modifier(OverviewSubmenuLabel(progress: childProgress))
                            }
                            // Keep the retiring tint with the displayed title;
                            // a new tint transaction would compete with its return.
                            .buttonStyle(OverviewTagButtonStyle(active: displayedSelection.map {
                                $0.kind == .semantic && child.matches($0.tag, kind: .semantic, scope: $0.scope)
                            } ?? false))
                            .glassEffectID(child.id, in: namespace)
                            .glassEffectTransition(.identity)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: OverviewSubmenuWidths.self, value: [child.id: geometry.size.width])
                                }
                            }
                            .modifier(OverviewSubmenuMorph(progress: reduceMotion ? 1 : childProgress,
                                target: target, originX: menu.children.filter { $0.count > 0 }.prefix { $0.id != child.id }
                                    .reduce(0) { $0 + (widths[$1.id] ?? 0) + OverviewTagMetrics.submenuSpacing }))
                            .modifier(OverviewSubmenuSurface(progress: reduceMotion ? 1 : childProgress))
                            .opacity(reduceMotion && childProgress == 0 ? 0 : 1)
                            .transition(.identity)
                            .allowsHitTesting(active && current)
                            .accessibilityHidden(!active || !current)
                            .focused($focusedTag, equals: child.id)
                            .overviewSearchAnchor(child.id)
                            .accessibilityIdentifier(child.id)
                            .accessibilityAddTraits(child.matches(selectedTag, kind: .semantic, scope: selectedScope) ? .isSelected : [])
                            .help(child.displayTag)
                        }
                    }
                }
                .nativeCanvasNavigationRegion()
                .modifier(NativeOverviewMenuRegistration(registry: interactions, root: interactionOwner, id: parent.id))
                // Keep identities mounted until their geometry reaches the
                // parent. Removing glass early loses the return destination.
                .transition(.identity)
                // Retiring views cannot act or remain in the accessibility tree.
                .allowsHitTesting(active)
                .accessibilityHidden(!active)
            }
        }
        .fixedSize()
        .padding(.top, OverviewTagMetrics.submenuSpacing)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoverClearTask?.cancel() } else if hoveredScope == parent.scope { scheduleHoverClear() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strings.filter)
    }

    private func isActive(_ filter: NativeOverviewFilter) -> Bool {
        (filter.isDirectory && selectedKind == .semantic && !selectedTag.isEmpty && selectedScope == filter.scope)
            || (!selectedTag.isEmpty && filter.matches(selectedTag, kind: selectedKind, scope: selectedScope))
    }

    private func setHoveredScope(_ scope: String?) {
        guard hoveredScope != scope else { return }
        var transaction = Transaction(animation: reduceMotion ? nil : scope == nil
            ? .easeInOut(duration: 0.32) : .smooth(duration: 0.22, extraBounce: 0))
        transaction.disablesAnimations = reduceMotion
        trackSubmenuTransition(to: scope, in: &transaction)
        withTransaction(transaction) {
            retainClosingMenu(to: scope)
            hoveredScope = scope
        }
    }

    private func retainClosingMenu(to scope: String?) {
        // Snapshot and visibility must change in the same transaction; otherwise
        // SwiftUI can coalesce the retained row into an unanimated update.
        if let oldScope = hoveredScope, oldScope != scope,
           let parent = presentedFilters.first(where: { $0.isDirectory && $0.scope == oldScope }) {
            if retiringMenus[oldScope] == nil { retiringMenus[oldScope] = parent }
        }
        if let scope { retiringMenus[scope] = nil }
    }

    private func trackSubmenuTransition(to scope: String?, in transaction: inout Transaction) {
        submenuRevision += 1
        let revision = submenuRevision
        submenuClosing = scope == nil
        // .removed includes the retiring glass surfaces, rather than only the
        // spring's logical completion. A reopened menu invalidates this callback.
        transaction.addAnimationCompletion(criteria: .removed) {
            guard submenuRevision == revision else { return }
            var cleanup = Transaction(animation: reduceMotion ? nil : .easeInOut(duration: 0.28))
            cleanup.disablesAnimations = reduceMotion
            withTransaction(cleanup) { retiringMenus = [:] }
            guard hoveredScope == nil else { return }
            submenuClosing = false
            // The menu's removed transaction has ended. Give the title its own
            // transaction so text and chip geometry do not jump on this frame.
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                displayedSelection = latestSelection
            }
        }
    }

    private func revealChildren(of filter: NativeOverviewFilter) {
        guard !isSearching, !searchMorphVisible, filter.isDirectory,
              filter.children.contains(where: { $0.count > 0 }) else { return }
        hoverClearTask?.cancel()
        setHoveredScope(filter.scope)
    }

    private func selectChild(_ child: NativeOverviewFilter, of parent: NativeOverviewFilter) {
        guard hoveredScope == parent.scope, !isSearching, !searchMorphVisible,
              presentedFilters.contains(where: {
                  $0.id == parent.id && $0.children.contains { $0.id == child.id && $0.count > 0 }
              }) else { return }
        selectFilter(child)
    }

    private func scheduleHoverClear() {
        hoverClearTask?.cancel()
        hoverClearTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(180)) }
            catch { return }
            guard !Task.isCancelled else { return }
            setHoveredScope(nil)
        }
    }

    private func filterButtons(maximumWidth: CGFloat) -> some View {
        HStack(spacing: OverviewTagMetrics.spacing) {
            Button {
                selectFilter(nil)
            } label: {
                Text(strings.all).font(NativeTypography.inter(size: OverviewTagMetrics.chipFont, weight: 620))
                    .padding(.horizontal, OverviewTagMetrics.chipLabelInset)
                    .frame(height: OverviewTagMetrics.chipHeight)
            }
            .buttonStyle(OverviewTagButtonStyle(active: selectedTag.isEmpty))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredAllWidth = $0 }
            .overviewSearchAnchor("__all__")
            .focused($focusedTag, equals: "__all__")
            .accessibilityAddTraits(selectedTag.isEmpty ? .isSelected : [])
            OverviewHorizontalScroll(interactions: interactions, owner: interactionOwner, ids: presentedFilters.map(\.id), enabled: !isSearching && !searchMorphVisible) {
                // Keep the effect container inside the scroll viewport. A
                // container outside it can draw captured labels beyond its clip.
                GlassEffectContainer(spacing: OverviewTagMetrics.spacing) {
                    scrollingTagButtons(maximumButtonWidth: max(0, maximumWidth - measuredAllWidth
                        - OverviewTagMetrics.barInset * 2 - OverviewTagMetrics.spacing))
                }
            }
            .frame(height: OverviewTagMetrics.chipHeight)
            .overviewSearchAnchor("__scroll__")
        }
        .padding(.horizontal, OverviewTagMetrics.barInset)
    }

    private func scrollingTagButtons(maximumButtonWidth: CGFloat) -> some View {
        HStack(spacing: OverviewTagMetrics.spacing) {
            ForEach(presentedFilters) { filter in
                let active = isActive(filter)
                Button {
                    selectFilter(filter)
                } label: {
                    HStack(spacing: OverviewTagMetrics.chipContentSpacing) {
                        if filter.isDirectory {
                            OverviewTagPrefix(emoji: displayedChild(of: filter)?.emoji)
                        }
                        OverviewTagTitle(title: filter.displayTag, child: displayedChild(of: filter)?.tag)
                        Text(String(filter.count))
                            .font(NativeTypography.inter(size: OverviewTagMetrics.countFont, weight: 680))
                            .frame(minWidth: OverviewTagMetrics.countMinWidth)
                            .padding(.horizontal, OverviewTagMetrics.countHorizontalInset)
                            .padding(.vertical, OverviewTagMetrics.countVerticalInset)
                            .background(.foreground.opacity(0.08), in: Capsule())
                    }
                    .padding(.horizontal, OverviewTagMetrics.chipLabelInset)
                    .frame(height: OverviewTagMetrics.chipHeight)
                    .frame(maxWidth: maximumButtonWidth)
                }
                .buttonStyle(OverviewTagButtonStyle(active: active, rendersGlass: !filter.isDirectory))
                .glassEffectID(filter.id, in: tagGlass)
                .glassEffectTransition(.matchedGeometry)
                .overviewSearchAnchor(filter.id)
                .focused($focusedTag, equals: filter.id)
                .accessibilityIdentifier(filter.id)
                .accessibilityAddTraits(active ? .isSelected : [])
                .accessibilityValue("\(filterTitle(filter)) · \(filter.count)")
                .accessibilityHint(filter.isDirectory && filter.children.contains(where: { $0.count > 0 }) ? strings.filter : "")
                .accessibilityAction(named: Text(hoveredScope == filter.scope ? strings.closeFilter : strings.filter)) {
                    if hoveredScope == filter.scope {
                        closeChildren()
                    } else { revealChildren(of: filter) }
                }
                .onHover { inside in
                    guard filter.isDirectory, filter.children.contains(where: { $0.count > 0 }) else { return }
                    if inside { revealChildren(of: filter) } else { scheduleHoverClear() }
                }
                .help(filterHint(filter))
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            // The scroll viewport is sized from this measurement in a later
            // update; carry the resize animation across that layout boundary.
            withAnimation(reduceMotion || measuredTagsWidth == 0 ? nil : .easeInOut(duration: 0.28)) {
                measuredTagsWidth = width
            }
        }
    }

    private var naturalFilterWidth: CGFloat {
        measuredAllWidth > 0 && measuredTagsWidth > 0
            ? measuredAllWidth + measuredTagsWidth + OverviewTagMetrics.barInset * 2 + OverviewTagMetrics.spacing : 10000
    }

    private func iconButton(_ name: String, size: CGFloat = 16, title: String, active: Bool = false,
                            settingsAnchor: OverviewSettingsAnchor? = nil,
                            onSettingsFrameChange: ((CGRect?) -> Void)? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NativeIcon(name: name, size: size)
                .frame(width: OverviewTagMetrics.iconButtonSize, height: OverviewTagMetrics.iconButtonSize)
                .frame(width: OverviewTagMetrics.actionDiameter, height: OverviewTagMetrics.actionDiameter)
        }
        .buttonStyle(OverviewChromeIconStyle(active: active, settingsAnchor: settingsAnchor,
                                            onSettingsFrameChange: onSettingsFrameChange))
        .glassEffectID(name, in: actionGlass)
        .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
        .help(title).accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func filterHint(_ filter: NativeOverviewFilter) -> String {
        let label = filter.isDirectory && !filter.scope.isEmpty && filter.scope != NativeOverviewSelection.inboxScope
            ? "\(filterTitle(filter)) — \(filter.scope)" : filterTitle(filter)
        return (filter.isDirectory ? strings.directoryPrefix : "") + label +
            (filter.aliases.isEmpty ? "" : strings.aliasPrefix + filter.aliases.joined(separator: "、"))
    }

    private func consumeFocus(_ request: Int) {
        if request != 0 { pendingFilterFocus = request }
        guard pendingFilterFocus != 0, !isSearching, !searchMorphVisible else { return }
        focusedTag = filters.isEmpty ? nil : (filters.first(where: { $0.matches(selectedTag, kind: selectedKind, scope: selectedScope) })?.id ?? "__all__")
        pendingFilterFocus = 0
        onFocusFilterRequestConsumed?()
    }

    private func presentFilters(_ updated: [NativeOverviewFilter], animated: Bool) {
        // A local presentation transaction keeps card/camera/settings updates out
        // of this animation. Initial hydration is immediate.
        var transaction = Transaction(animation: animated ? .smooth(duration: 0.48, extraBounce: 0) : nil)
        transaction.disablesAnimations = !animated
        let closesMenu = hoveredScope.map { scope in
            !updated.contains { $0.isDirectory && $0.scope == scope && $0.children.contains { $0.count > 0 } }
        } ?? false
        let changedMenu = hoveredScope.flatMap { scope in
            presentedFilters.first { parent in
                parent.isDirectory && parent.scope == scope && parent.children.contains { child in
                    !updated.contains { $0.scope == scope && $0.children.contains { $0.id == child.id && $0.count > 0 } }
                }
            }
        }
        if closesMenu {
            hoverClearTask?.cancel()
            trackSubmenuTransition(to: nil, in: &transaction)
        } else if changedMenu != nil {
            trackSubmenuTransition(to: hoveredScope, in: &transaction)
        }
        withTransaction(transaction) {
            if let changedMenu, retiringMenus[changedMenu.scope] == nil { retiringMenus[changedMenu.scope] = changedMenu }
            if closesMenu {
                retainClosingMenu(to: nil)
                hoveredScope = nil
            }
            presentedFilters = updated
            if !updated.isEmpty && !hasPresentedFilters { hasPresentedFilters = true }
            if updated.isEmpty {
                focusedTag = nil
            } else if let focusedTag, focusedTag != "__all__", !updated.contains(where: { $0.id == focusedTag || $0.children.contains { $0.id == focusedTag } }) {
                self.focusedTag = "__all__"
            }
        }
    }
}

/// Shared with the search carrier so entering search cannot restore the old
/// slash separator or change the hierarchy's text layout for its first frame.
struct OverviewTagTitle: View {
    let title: String
    var child: String?

    var body: some View {
        HStack(spacing: OverviewTagMetrics.chipContentSpacing) {
            Text(title).contentTransition(.opacity)
            if let child {
                Divider().frame(height: 14).accessibilityHidden(true).transition(.opacity)
                Text(child).contentTransition(.opacity).transition(.opacity)
            }
        }
        .font(NativeTypography.inter(size: OverviewTagMetrics.chipFont, weight: 620))
        .lineLimit(1)
        .truncationMode(child == nil ? .tail : .middle)
        .clipped()
    }
}

struct OverviewTagPrefix: View {
    var emoji: String?
    var body: some View {
        ZStack {
            if let emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: OverviewTagMetrics.folderIcon))
                    .id(emoji).transition(.opacity)
            } else {
                NativeIcon(name: "Folder", size: OverviewTagMetrics.folderIcon).opacity(0.72)
                    .transition(.opacity)
            }
        }
        // Emoji advance and line bounds can exceed the point size. Preserve
        // native glyph layout instead of proposing an icon-sized square to Text.
        .fixedSize()
        .frame(minWidth: OverviewTagMetrics.folderIcon)
        .accessibilityHidden(true)
    }
}

public struct NativeOverviewChromeStrings: Sendable {
    public var all = "全部"
    public var returnToAuto = "回到自动视图"
    public var settings = "设置"
    public var restart = "重启开发应用"
    public var actions = "俯瞰视图操作"
    public var search = "搜索会话"
    public var searchIn = "搜索范围："
    public var closeSearch = "退出搜索（Esc）"
    public var filter = "按标签筛选"
    public var closeFilter = "关闭子标签菜单"
    public var directoryPrefix = "工作目录标签："
    public var aliasPrefix = "；别名："
    public init() {}
}

/// Same noninteractive empty and offscreen-attention treatments as the renderer.
public struct NativeOverviewEmptyState: View {
    public var title: String
    public var detail: String
    public init(title: String = "还没有会话", detail: String = "切换视图或标签筛选以查看其他 Thread。") {
        self.title = title; self.detail = detail
    }
    public var body: some View {
        VStack(spacing: 5) {
            Text(title).font(NativeTypography.inter(size: 11.5, weight: 590)).foregroundStyle(NativePalette.overview.muted.swiftUI)
            Text(detail).font(NativeTypography.inter(size: 10)).foregroundStyle(NativePalette.overview.faint.swiftUI)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

public struct NativeOverviewAttentionIndicator: View {
    public var text: String
    public init(text: String) { self.text = text }
    public var body: some View {
        HStack(spacing: 6) {
            NativeIcon(name: "CircleAlert", size: 13)
            Text(text).font(NativeTypography.inter(size: 12, weight: 620))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .foregroundStyle(NativePalette.overview.ink.swiftUI)
        .background(NativePalette.overview.surfaceSoft.swiftUI, in: Capsule())
        .overlay(Capsule().stroke(NativePalette.overview.line.swiftUI, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 13, y: 10)
        .allowsHitTesting(false)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

enum OverviewTagMetrics {
    static let iconButtonSize: CGFloat = 30
    static let actionInset: CGFloat = 5
    static let buttonHeight = iconButtonSize + actionInset * 2
    static let barInset: CGFloat = 6
    static let labelInset: CGFloat = 12
    static let spacing: CGFloat = 4
    // Match both the row gap and child gap to the native morph distance. Each
    // directory has its own container, so unrelated parents never fuse at rest.
    static let submenuSpacing: CGFloat = 10
    /// Tag-filter chips only. Typography, icon and spacing are 12.5% above the
    /// 10.5 / 8.5 / 11 / 12 metrics they previously used; the height is pinned
    /// independently so the bar and the circular action buttons stay in step.
    static let chipScale: CGFloat = 1.125
    static let chipFont = 10.5 * chipScale
    static let countFont = 8.5 * chipScale
    static let folderIcon = 11 * chipScale
    static let chipContentSpacing = 6 * chipScale
    static let chipLabelInset = labelInset * chipScale
    static let countHorizontalInset = 4 * chipScale
    static let countVerticalInset = 1 * chipScale
    static let countMinWidth = 6 * chipScale
    /// Shared by the tag-filter bar and the action buttons.
    static let chipHeight: CGFloat = 42
    /// Action buttons are circles matching the tag bar height. Equal width and
    /// height keep the glass from stretching into a vertical ellipse, while
    /// the shared diameter keeps both controls aligned edge to edge.
    static let actionDiameter = chipHeight
    static let barHeight = chipHeight
    /// Always reserve a caption band below the narrow action row, including
    /// when no child is selected. Its appearance cannot move the filter bar.
    static let narrowFilterTop: CGFloat = 76
    static let chromeHeight = narrowFilterTop + chipHeight + 4
    /// Card clearance keeps the previous 2pt gap under the tag bar.
    static let wideToolbarClearance = 18 + chipHeight
    static let narrowToolbarClearance = narrowFilterTop + chipHeight + 2
}

/// One persistent source surface per directory anchors its child menu. The
/// menu's glass container stays inside its scroll viewport to respect clipping.
/// macOS 26 is the package deployment target, matching these APIs' availability.
private struct OverviewDirectoryGlassGroup<Children: View>: View {
    let parent: NativeOverviewFilter
    let source: CGRect
    let visible: CGRect
    let barWidth: CGFloat
    let active: Bool
    @ViewBuilder var children: (Namespace.ID) -> Children
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: OverviewTagMetrics.submenuSpacing) {
            Color.clear
                .frame(width: visible.width, height: visible.height)
                .modifier(OverviewTagGlassSurface(active: active,
                    shape: OverviewClippedTagShape(leadingOverflow: visible.minX - source.minX,
                        trailingOverflow: source.maxX - visible.maxX)))
                .glassEffectID(parent.id, in: glass)
                .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .overlay(alignment: .top) {
                    children(glass)
                        // Use the measured child width without a state update on
                        // first reveal. Keep the row inside the bar when it fits.
                        .alignmentGuide(HorizontalAlignment.center) { [barWidth, parentCenter = visible.midX] dimensions in
                            let width = dimensions.width
                            let center = width > barWidth ? barWidth / 2
                                : min(max(parentCenter, width / 2), barWidth - width / 2)
                            return width / 2 + parentCenter - center
                        }
                        .offset(y: visible.height)
                }
        }
        .frame(width: visible.width, height: visible.height)
        .position(x: visible.midX, y: visible.midY)
    }
}

/// Preserve the actual clipped capsule edge when a parent is partly scrolled
/// offscreen, rather than drawing a new rounded end or capturing hidden text.
private struct OverviewClippedTagShape: Shape {
    var leadingOverflow: CGFloat
    var trailingOverflow: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(leadingOverflow, trailingOverflow) }
        set { leadingOverflow = newValue.first; trailingOverflow = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        // The glass frame interpolates during selection changes. An absolute
        // measured source size can lag that frame and slice off a capsule end.
        // Only offscreen overflow is external; the visible size belongs to rect.
        let capsule = CGRect(x: rect.minX - leadingOverflow, y: rect.minY,
            width: rect.width + leadingOverflow + trailingOverflow, height: rect.height)
        return Path(roundedRect: capsule, cornerRadius: rect.height / 2).intersection(Path(rect))
    }
}

private struct OverviewTagButtonStyle: ButtonStyle {
    let active: Bool
    var rendersGlass = true
    func makeBody(configuration: Configuration) -> some View {
        OverviewTagButtonBody(configuration: configuration, active: active, rendersGlass: rendersGlass)
    }
}

private struct OverviewTagButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    let rendersGlass: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if rendersGlass {
            configuration.label.modifier(OverviewTagGlassSurface(active: active, shape: Capsule()))
        } else {
            configuration.label
                .foregroundStyle(scheme == .dark ? .white : NativePalette.overview.ink.swiftUI)
                .contentShape(Capsule())
        }
    }
}

private struct OverviewTagGlassSurface<S: Shape>: ViewModifier {
    let active: Bool
    let shape: S
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .foregroundStyle(scheme == .dark ? .white : NativePalette.overview.ink.swiftUI)
            .background {
                if reduceTransparency {
                    shape.fill(Color(white: scheme == .dark ? 0.16 : 0.94))
                }
            }
            .contentShape(shape)
            .glassEffect(.clear.tint(active ? selectionTint : nil).interactive(), in: shape)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: active)
    }

    private var selectionTint: Color {
        NativePalette.overview.accent.swiftUI
            .opacity(contrast == .increased ? 0.34 : 0.22)
    }
}

private struct OverviewChromeIconStyle: ButtonStyle {
    let active: Bool
    var settingsAnchor: OverviewSettingsAnchor?
    var onSettingsFrameChange: ((CGRect?) -> Void)?
    func makeBody(configuration: Configuration) -> some View {
        OverviewChromeIconBody(configuration: configuration, active: active,
                               settingsAnchor: settingsAnchor, onSettingsFrameChange: onSettingsFrameChange)
    }
}

private struct OverviewChromeIconBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    var settingsAnchor: OverviewSettingsAnchor?
    var onSettingsFrameChange: ((CGRect?) -> Void)?
    var body: some View {
        OverviewTagButtonStyle(active: active).makeBody(configuration: configuration)
            .background {
                if let settingsAnchor {
                    OverviewSettingsFrameReader(anchor: settingsAnchor, onChange: onSettingsFrameChange)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

/// Long child menus scroll within the available toolbar width while short
/// menus retain their natural size and directory-relative placement.
private struct OverviewTagMenuViewport<Content: View>: View {
    let maximumWidth: CGFloat
    let active: Bool
    let source: CGRect
    let barWidth: CGFloat
    @ViewBuilder var content: (CGFloat, CGRect, [String: CGFloat]) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentWidth: CGFloat?
    @State private var entered = false
    @State private var widths: [String: CGFloat] = [:]
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        let width = min(contentWidth ?? maximumWidth, maximumWidth)
        let center = width > barWidth ? barWidth / 2 : min(max(source.midX, width / 2), barWidth - width / 2)
        let target = CGRect(x: source.midX - center + width / 2 + scrollOffset - source.width / 2,
            y: -OverviewTagMetrics.submenuSpacing - source.height, width: source.width, height: source.height)
        // The morph starts at the parent, which can be wider than a short
        // child row. Clip to both endpoints in viewport coordinates so the
        // moving capsule keeps its rounded ends. Overflowing rows still clip
        // horizontally: their viewport already contains the parent.
        let clipBounds = CGRect(x: 0, y: 0, width: width, height: OverviewTagMetrics.chipHeight)
            .insetBy(dx: 0, dy: -OverviewTagMetrics.chipHeight - OverviewTagMetrics.submenuSpacing)
            .union(target.offsetBy(dx: -scrollOffset, dy: 0))
        NativeScrollView(.horizontal) {
            // Glass captures its labels. Keeping its container inside the
            // viewport prevents offscreen sibling labels escaping the clip.
            GlassEffectContainer(spacing: OverviewTagMetrics.submenuSpacing) {
                content(active && entered ? 1 : 0, target, widths)
                    .fixedSize(horizontal: true, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        withAnimation(reduceMotion || contentWidth == nil ? nil : .easeInOut(duration: 0.28)) {
                            contentWidth = width
                        }
                    }
            }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .scrollClipDisabled()
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in scrollOffset = offset }
        .frame(width: width, height: OverviewTagMetrics.chipHeight)
        .mask { Path(clipBounds) }
        // Measure before revealing, so the first frame cannot place short menus
        // at the leading edge of a full-width viewport.
        .opacity(contentWidth == nil ? 0 : 1)
        .onChange(of: contentWidth, initial: true) { _, width in
            if width != nil { revealMeasuredMenu() }
        }
        .onPreferenceChange(OverviewSubmenuWidths.self) { values in
            widths = values
            revealMeasuredMenu()
        }
    }

    private func revealMeasuredMenu() {
        guard contentWidth != nil, !widths.isEmpty, !entered else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22, extraBounce: 0)) { entered = true }
    }
}

private struct OverviewSubmenuWidths: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// Visual geometry never feeds back into row measurement. Retargeting samples
/// this same mounted modifier, including a close interrupted by reopening.
private struct OverviewSubmenuMorph: GeometryEffect {
    var progress: CGFloat
    let target: CGRect
    let originX: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let p = min(1, max(0, progress))
        return ProjectionTransform(CGAffineTransform(
            translationX: (target.midX - originX - size.width / 2) * (1 - p),
            y: (target.midY - size.height / 2) * (1 - p))
            .translatedBy(x: size.width / 2, y: size.height / 2)
            .scaledBy(x: 1 + (target.width / max(1, size.width) - 1) * (1 - p),
                      y: 1 + (target.height / max(1, size.height) - 1) * (1 - p))
            .translatedBy(x: -size.width / 2, y: -size.height / 2))
    }
}

private struct OverviewSubmenuSurface: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View { content.opacity(min(1, max(0, progress) / 0.25)) }
}

private struct OverviewSubmenuLabel: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let p = min(1, max(0, progress))
        content.opacity(p * p * p)
    }
}

/// The top-level bar retains its scroll identity through filter revisions.
private struct OverviewHorizontalScroll<Content: View>: View {
    let interactions: NativeOverviewChromeInteractions?
    let owner: UUID
    let ids: [String]
    let enabled: Bool
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollViewReader { proxy in
            NativeScrollView(.horizontal) {
                content()
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .modifier(NativeOverviewFilterScrollRegistration(registry: interactions, root: owner, ids: ids, enabled: enabled,
                scroll: { id in proxy.scrollTo(id, anchor: .center) }))
        }
    }
}

@MainActor private final class OverviewSettingsAnchor {
    var frame: CGRect?
}

private struct OverviewSettingsFrameReader: View {
    let anchor: OverviewSettingsAnchor
    var onChange: ((CGRect?) -> Void)?
    var body: some View {
        Color.clear
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workspace")) } action: { frame in
                anchor.frame = frame
                onChange?(frame)
            }
            .onDisappear { anchor.frame = nil; onChange?(nil) }
            .allowsHitTesting(false)
    }
}

private struct OverviewToolbarEntry: ViewModifier {
    @State private var entered = false
    func body(content: Content) -> some View {
        content.opacity(entered ? 1 : 0).offset(y: entered ? 0 : -6).scaleEffect(entered ? 1 : 0.98)
            .onAppear {
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.32)) { entered = true }
            }
    }
}

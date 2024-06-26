import AppKit
import SwiftUI

enum DetailTab: String, CaseIterable {
    case preview = "Preview"
    case contents = "Bundle"
    case info = "Info.plist"
    case prefs = "Preferences"
}

private struct PaneWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ContentView: View {
    @StateObject private var scanner = ScreenSaverScanner()
    @StateObject private var engine = PreviewEngine()

    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 360.0
    @AppStorage("customSaverPaths") private var customSaverPaths = ""
    @AppStorage("hiddenBundlePaths") private var hiddenBundlePaths = ""

    @State private var query = ""
    @State private var selection: ScreenSaverBundle.ID?
    @State private var customSavers: [ScreenSaverBundle] = []
    @State private var files: [SaverFile] = []
    @State private var moduleGroups: [PrefGroup] = []
    @State private var storeGroups: [PrefGroup] = []
    @State private var systemGroups: [PrefGroup] = []
    @State private var tab: DetailTab = .preview
    @State private var aerialPlaying = true
    @State private var addError: String?
    @State private var dragStartWidth: Double?
    @State private var hoveringHandle = false

    // MARK: - Data

    /// Everything found by the scanner plus the bundles the user added.
    private var knownBundles: [ScreenSaverBundle] { scanner.bundles + customSavers }

    private var hiddenPaths: Set<String> {
        Set(hiddenBundlePaths.split(separator: "\n").map(String.init))
    }

    private var hiddenCount: Int { hiddenPaths.count }

    /// What the sidebar and the detail pane show: known bundles minus the ones
    /// the user removed from the list.
    private var allBundles: [ScreenSaverBundle] {
        knownBundles.filter { !hiddenPaths.contains($0.id.path) }
    }

    private var active: ScreenSaverBundle? { allBundles.first { $0.id == selection } }

    private func isCustom(_ saver: ScreenSaverBundle) -> Bool {
        customSavers.contains { $0.id == saver.id }
    }

    private var filtered: [ScreenSaverBundle] {
        guard !query.isEmpty else { return allBundles }
        let needle = query.lowercased()
        return allBundles.filter {
            $0.name.lowercased().contains(needle)
                || $0.subtitle.lowercased().contains(needle)
                || $0.categoryNames.lowercased().contains(needle)
                || ($0.assetID?.lowercased().contains(needle) ?? false)
                || $0.location.lowercased().contains(needle)
        }
    }

    /// Discovered screen savers of a kind, without the ones the user added.
    private func items(of kind: SaverKind) -> [ScreenSaverBundle] {
        filtered.filter { $0.kind == kind && !isCustom($0) }
    }

    private var customItems: [ScreenSaverBundle] { filtered.filter(isCustom) }

    private var clampedSidebarWidth: CGFloat {
        min(max(CGFloat(sidebarWidth), 260), 620)
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar
                    .frame(minWidth: 240, idealWidth: clampedSidebarWidth, maxWidth: clampedSidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                sidebarHandle
            }

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(WindowLayoutConfigurator())
        .task {
            loadCustomSavers()
            if scanner.bundles.isEmpty {
                scanner.scan()
                if selection == nil { selection = defaultSelection() }
                loadDetails()
            }
        }
        .onChange(of: selection) { _, _ in
            engine.installedURL = nil   // force the preview to reload
            loadDetails()
        }
        .alert("Some items were skipped", isPresented: Binding(
            get: { addError != nil },
            set: { if !$0 { addError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addError ?? "")
        }
    }

    private func defaultSelection() -> ScreenSaverBundle.ID? {
        (allBundles.first { $0.isActive } ?? allBundles.first)?.id
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()
            searchField
            Divider()
            sidebarList
            Divider()
            sidebarFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Visual Saver").font(.headline)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { sidebarVisible = false }
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.borderless)
            .help("Hide the left panel (⌥⌘S)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter screen savers", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear the filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var sidebarList: some View {
        List(selection: $selection) {
            if !customItems.isEmpty {
                Section("Added by you — \(customItems.count)") {
                    ForEach(customItems) { saver in
                        rowWithMenu(for: saver)
                            .tag(saver.id)
                    }
                }
            }

            ForEach(SaverKind.allCases, id: \.self) { kind in
                let group = items(of: kind)
                if !group.isEmpty {
                    Section(kind.sectionTitle(count: group.count)) {
                        ForEach(group) { saver in
                            rowWithMenu(for: saver)
                                .tag(saver.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if let saver = active { removeFromList(saver) }
        }
        .overlay {
            if allBundles.isEmpty && !scanner.isScanning {
                ContentUnavailableView("No screen savers found", systemImage: "sparkles.tv")
            } else if !query.isEmpty && customItems.isEmpty && SaverKind.allCases.allSatisfy({ items(of: $0).isEmpty }) {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func rowWithMenu(for saver: ScreenSaverBundle) -> some View {
        row(for: saver)
            .contextMenu {
                Button("Remove from list", role: .destructive) { removeFromList(saver) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([saver.id])
                }
                if isCustom(saver) {
                    Divider()
                    Button("Forget this added screen saver") { removeFromList(saver) }
                }
            }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            Button {
                addScreenSavers()
            } label: {
                Label("Add screen saver…", systemImage: "plus")
            }
            .help("Load a .saver bundle from anywhere on this Mac")

            Spacer(minLength: 0)

            if let saver = active {
                if saver.kind == .aerial {
                    Button {
                        aerialPlaying.toggle()
                    } label: {
                        Image(systemName: aerialPlaying ? "pause.fill" : "play.fill")
                    }
                    .disabled(saver.video == nil)
                    .help(aerialPlaying ? "Pause the preview video" : "Play the preview video")
                } else if saver.kind == .plugin {
                    Button {
                        engine.stage()
                    } label: {
                        Image(systemName: engine.running ? "stop.fill" : "play.fill")
                    }
                    .help(engine.running ? "Stop the screen saver" : "Start the screen saver")
                }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([saver.id])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal \(saver.name) in the Finder")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Draggable divider between the panel and the detail view.
    private var sidebarHandle: some View {
        ZStack {
            Divider()
            Rectangle()
                .fill(Color.clear)
                .frame(width: 9)
                .contentShape(Rectangle())
                .onHover { inside in
                    // Guard against repeated same-value callbacks: unbalanced
                    // push/pop pairs make the pointer flicker.
                    guard inside != hoveringHandle else { return }
                    hoveringHandle = inside
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .onDisappear {
                    if hoveringHandle {
                        NSCursor.pop()
                        hoveringHandle = false
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStartWidth == nil { dragStartWidth = sidebarWidth }
                            let start = dragStartWidth ?? sidebarWidth
                            sidebarWidth = Double(min(max(CGFloat(start) + value.translation.width, 260), 620))
                        }
                        .onEnded { _ in dragStartWidth = nil }
                )
                .help("Drag to resize the panel, double-click to reset")
                .onTapGesture(count: 2) { sidebarWidth = 360 }
        }
        .frame(width: 9)
    }

    private var subtitle: String {
        let plugins = items(of: .plugin).count
        let providers = items(of: .provider).count
        let aerials = items(of: .aerial).count
        var text = "\(plugins) plugins · \(providers) providers · \(aerials) Aerial"
        if !customSavers.isEmpty { text += " · \(customSavers.count) added" }
        return text
    }

    private func row(for saver: ScreenSaverBundle) -> some View {
        // Badge is dropped automatically when the sidebar is too narrow to fit it.
        ViewThatFits(in: .horizontal) {
            rowContent(for: saver, showBadge: true)
            rowContent(for: saver, showBadge: false)
        }
        .padding(.vertical, 1)
        .help("\(saver.name)\n\(saver.subtitle)\n\(saver.id.path)")
    }

    private func rowContent(for saver: ScreenSaverBundle, showBadge: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: saver.kind.symbolName)
                    .foregroundStyle(color(for: saver))
                    .font(.caption)
                Text(saver.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if saver.isBroken {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help(saver.issue ?? "")
                }
                if showBadge {
                    Spacer(minLength: 6)
                    if isCustom(saver) {
                        badge("Added", color: .purple)
                    } else {
                        badge(saver.isActive ? "Active" : saver.badgeText,
                              color: saver.isBroken ? .orange : (saver.isActive ? .green : color(for: saver)))
                    }
                }
            }
            Text(saver.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(for saver: ScreenSaverBundle) -> Color {
        if saver.isBroken { return .orange }
        if isCustom(saver) { return .purple }
        switch saver.kind {
        case .plugin: return saver.isSystem ? .yellow : .blue
        case .provider: return .purple
        case .aerial: return saver.video != nil ? .green : .teal
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }

    // MARK: - Detail pane

    private var detail: some View {
        VStack(spacing: 0) {
            detailBar
            Divider()
            if let saver = active {
                SaverDetail(
                    saver: saver,
                    engine: engine,
                    files: files,
                    moduleGroups: moduleGroups,
                    storeGroups: storeGroups,
                    systemGroups: systemGroups,
                    tab: $tab,
                    aerialPlaying: $aerialPlaying,
                    reload: loadDetails,
                    remove: { if let saver = active { removeFromList(saver) } }
                )
            } else {
                ContentUnavailableView(
                    "No screen saver selected",
                    systemImage: "sparkles.tv",
                    description: Text("Choose an item in the left panel — or add a .saver bundle from anywhere on this Mac with the “Add screen saver…” button.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detailBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { sidebarVisible.toggle() }
            } label: {
                Label(sidebarVisible ? "Hide panel" : "Show panel", systemImage: "sidebar.leading")
            }
            .help(sidebarVisible ? "Hide the left panel (⌥⌘S)" : "Show the left panel (⌥⌘S)")
            .keyboardShortcut("s", modifiers: [.command, .option])

            Spacer(minLength: 8)

            if let saver = active {
                Button {
                    removeFromList(saver)
                } label: {
                    Label(isCustom(saver) ? "Remove from list" : "Hide from list", systemImage: "eye.slash")
                }
                .help("Take \(saver.name) out of the list (nothing is deleted from disk)")
            }

            if hiddenCount > 0 {
                Button {
                    restoreHidden()
                } label: {
                    Label("Restore \(hiddenCount) hidden", systemImage: "arrow.uturn.backward")
                }
                .help("Show the screen savers you removed from the list again")
            }

            Button {
                addScreenSavers()
            } label: {
                Label("Add screen saver…", systemImage: "plus")
            }
            .help("Load a .saver bundle from anywhere on this Mac")

            Button {
                scanner.scan()
                loadDetails()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Rescan plugins, providers and Aerial videos")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Custom screen savers

    private func addScreenSavers() {
        let panel = NSOpenPanel()
        panel.title = "Add screen savers"
        panel.message = "Choose one or more .saver bundles — or a folder that contains them (for example a download folder)."
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        addCustom(panel.urls)
    }

    private func addCustom(_ urls: [URL]) {
        var added: [ScreenSaverBundle] = []
        var rejected: [String] = []

        for url in urls {
            let candidates = saverBundleURLs(in: url)
            if candidates.isEmpty {
                rejected.append(url.lastPathComponent)
                continue
            }
            for candidate in candidates {
                guard let bundle = ScreenSaverScanner.describePlugin(candidate) else {
                    rejected.append(candidate.lastPathComponent)
                    continue
                }
                if !knownBundles.contains(where: { $0.id == bundle.id })
                    && !added.contains(where: { $0.id == bundle.id }) {
                    added.append(bundle)
                }
            }
        }

        customSavers.append(contentsOf: added)
        saveCustomSaverPaths()
        if !added.isEmpty {
            // Adding something that was previously removed brings it back.
            let addedPaths = Set(added.map(\.id.path))
            let remaining = hiddenPaths.subtracting(addedPaths)
            if remaining.count != hiddenPaths.count {
                hiddenBundlePaths = remaining.sorted().joined(separator: "\n")
            }
            selection = added[0].id
        }

        if !rejected.isEmpty {
            addError = "These items do not look like screen savers (.saver bundles with a Contents/Info.plist):\n\n"
                + rejected.joined(separator: "\n")
        }
    }

    /// A `.saver` bundle itself, or every `.saver` bundle inside a folder.
    private func saverBundleURLs(in url: URL) -> [URL] {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        if url.pathExtension.lowercased() == "saver" {
            return FileManager.default.fileExists(atPath: infoURL.path) ? [url] : []
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }

        var found: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for case let item as URL in enumerator {
                guard item.pathExtension.lowercased() == "saver" else { continue }
                enumerator.skipDescendants()
                if FileManager.default.fileExists(atPath: item.appendingPathComponent("Contents/Info.plist").path) {
                    found.append(item)
                }
            }
        }
        return found
    }

    /// Takes an item out of the list. User-added savers are forgotten entirely;
    /// anything else is remembered as hidden so it stays gone after a relaunch.
    private func removeFromList(_ saver: ScreenSaverBundle) {
        let wasSelected = selection == saver.id
        customSavers.removeAll { $0.id == saver.id }
        saveCustomSaverPaths()

        var paths = hiddenPaths
        paths.insert(saver.id.path)
        hiddenBundlePaths = paths.sorted().joined(separator: "\n")

        if wasSelected {
            selection = defaultSelection()
            loadDetails()
        }
    }

    private func restoreHidden() {
        let wasHidden = selection.map { hiddenPaths.contains($0.path) } ?? false
        hiddenBundlePaths = ""
        if wasHidden || active == nil {
            selection = defaultSelection()
        }
        loadDetails()
    }

    private func saveCustomSaverPaths() {
        customSaverPaths = customSavers.map(\.id.path).joined(separator: "\n")
    }

    private func loadCustomSavers() {
        let paths = customSaverPaths.split(separator: "\n").map(String.init)
        if !paths.isEmpty {
            customSavers = paths.compactMap { path in
                FileManager.default.fileExists(atPath: path)
                    ? ScreenSaverScanner.describePlugin(URL(fileURLWithPath: path))
                    : nil
            }
            if customSavers.count != paths.count { saveCustomSaverPaths() }
        }

        // Drop hidden entries whose file has gone away in the meantime.
        let live = hiddenPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if live.count != hiddenPaths.count {
            hiddenBundlePaths = live.sorted().joined(separator: "\n")
        }
    }

    // MARK: - Detail loading

    private func loadDetails() {
        guard let saver = active else {
            files = []
            moduleGroups = []
            storeGroups = []
            systemGroups = []
            return
        }
        switch saver.kind {
        case .plugin:
            files = ScreenSaverScanner.contents(of: saver.id)
            moduleGroups = PreferencesReader.moduleGroups(bundleID: saver.bundleID, displayName: saver.name)
        case .provider:
            files = ScreenSaverScanner.contents(of: saver.id)
            moduleGroups = PreferencesReader.containerGroups(bundleID: saver.bundleID)
        case .aerial:
            files = []
            moduleGroups = []
        }
        storeGroups = WallpaperStore.groups()
        systemGroups = PreferencesReader.systemGroups()
        ScreenSaverScanner.refreshActiveSelection()
    }
}

extension PreviewEngine {
    func stage() {
        host?.toggleAnimation()
        running.toggle()
    }
}

// MARK: - Detail pane

struct SaverDetail: View {
    let saver: ScreenSaverBundle
    @ObservedObject var engine: PreviewEngine
    let files: [SaverFile]
    let moduleGroups: [PrefGroup]
    let storeGroups: [PrefGroup]
    let systemGroups: [PrefGroup]
    @Binding var tab: DetailTab
    @Binding var aerialPlaying: Bool
    let reload: () -> Void
    /// Takes this item out of the list (used by the “cannot run” notice).
    let remove: () -> Void

    /// Width of the tab area; the preview box is derived from it so the live
    /// view always fits the pane exactly (no clipping, no oversized window).
    @State private var paneWidth: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Picker("Section", selection: $tab) {
                ForEach(DetailTab.allCases, id: \.self) { item in
                    Text(label(for: item)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            tabContent
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
        .padding(14)
        .alert("This screen saver does not provide a configuration sheet.", isPresented: $engine.showNoSheetAlert) {}
    }

    @ViewBuilder
    private var tabContent: some View {
        tabBody
    }

    private var tabBody: some View {
        Group {
            switch tab {
            case .preview: preview
            case .contents: fileTable
            case .info: infoTable
            case .prefs: prefsView
            }
        }
        // A vertical ScrollView reports its content's height as its ideal
        // height; capping the ideals keeps the window at a sane size while the
        // explicit minimums let it shrink all the way to the window minimum.
        .frame(minWidth: 360, idealWidth: 820, maxWidth: .infinity,
               minHeight: 200, idealHeight: 380, maxHeight: .infinity,
               alignment: .topLeading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PaneWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(PaneWidthKey.self) { width in
            if width > 0 { paneWidth = width }
        }
    }

    private func label(for item: DetailTab) -> String {
        switch item {
        case .preview: return item.rawValue
        case .contents:
            return saver.kind == .aerial ? "Files" : "Bundle (\(files.count))"
        case .info:
            return saver.kind == .aerial ? "Metadata (\(saver.infoEntries.count))" : "Info.plist (\(saver.infoEntries.count))"
        case .prefs:
            return "Preferences (\(moduleGroups.reduce(0) { $0 + $1.entries.count } + storeGroups.reduce(0) { $0 + $1.entries.count }))"
        }
    }

    // MARK: Preview sizing

    /// 16:9 box that fits the pane; the embedded screen saver fills it exactly.
    private var previewBoxWidth: CGFloat {
        min(max(paneWidth - 4, 240), 900)
    }

    private var previewBoxHeight: CGFloat {
        (previewBoxWidth * 9 / 16).rounded()
    }

    @ViewBuilder
    private func previewBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: previewBoxWidth, height: previewBoxHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    // MARK: Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerWide
            headerNarrow
        }
        .padding(.bottom, 2)
    }

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: saver.kind.symbolName)
                    .foregroundStyle(.secondary)
                Text(saver.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                if saver.isActive {
                    Text("Active").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green.opacity(0.2)).clipShape(Capsule())
                }
            }
            Text(saver.kind == .aerial ? saver.subtitle : saver.bundleID)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Wide layout: details in a right-hand column of label/value pairs.
    private var headerWide: some View {
        HStack(alignment: .top, spacing: 12) {
            titleRow
            Spacer(minLength: 12)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(Array(saver.headerRows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0).foregroundStyle(.secondary)
                        Text(row.1)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .font(.caption)
        }
    }

    /// Narrow layout: the same details stacked underneath the title, wrapping.
    private var headerNarrow: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleRow
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(saver.headerRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.0).foregroundStyle(.secondary)
                        Text(row.1)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        switch saver.kind {
        case .plugin:
            VStack(alignment: .leading, spacing: 8) {
                if let issue = saver.issue {
                    unbuildableNotice(issue)
                } else {
                    previewBox {
                        PreviewRepresentable(engine: engine, bundleURL: saver.id)
                    }

                    HStack(spacing: 8) {
                        Button {
                            engine.stage()
                        } label: {
                            Label(engine.running ? "Stop" : "Start", systemImage: engine.running ? "stop.fill" : "play.fill")
                        }
                        Button {
                            engine.configure()
                        } label: {
                            Label("Open configuration…", systemImage: "slider.horizontal.3")
                        }
                        .disabled(!engine.canConfigure)
                        Spacer()
                    }
                    .controlSize(.small)
                }

                Text(engine.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .aerial:
            VStack(alignment: .leading, spacing: 8) {
                previewBox {
                    AerialPreviewView(thumbnail: saver.thumbnail, video: saver.video,
                                      remote: saver.remotePreview, playing: aerialPlaying)
                }

                HStack(spacing: 8) {
                    Button {
                        aerialPlaying.toggle()
                    } label: {
                        Label(aerialPlaying ? "Pause" : "Play", systemImage: aerialPlaying ? "pause.fill" : "play.fill")
                    }
                    .disabled(saver.video == nil)
                    Text(saver.video != nil
                         ? "Playing the downloaded 4K video from ~/Library/Application Support/com.apple.wallpaper/aerials/videos"
                         : "Video not downloaded yet — showing the cached thumbnail. System Settings downloads it when the saver is used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .provider:
            VStack(alignment: .leading, spacing: 8) {
                Text("\(saver.name) is an ExtensionKit provider (extension point \(WallpaperCatalog.providerPoint)).")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("macOS runs it in its own process to supply built-in screen savers and wallpapers, so it cannot be embedded here the way a classic .saver plugin can. Its settings, the screen savers it registers and its extension preferences are shown in the other tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("Related items in this app").font(.callout).fontWeight(.medium)
                if saver.providerID == WallpaperCatalog.aerialsProviderID {
                    Text("Aerial videos — \(WallpaperCatalog.aerialAssets().count) assets, listed in the sidebar.").font(.caption)
                }
                Text("Current screen saver choices are in the Preferences tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Bundle / files

    /// Shown instead of a live preview when a bundle cannot run at all.
    private func unbuildableNotice(_ issue: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("This screen saver cannot run").font(.callout).fontWeight(.semibold)
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([saver.id])
                    } label: {
                        Label("Show it in the Finder", systemImage: "folder")
                    }
                    Button {
                        remove()
                    } label: {
                        Label("Remove from list", systemImage: "eye.slash")
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
                Text("The Bundle, Info.plist and Preferences tabs still work for this item.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.4)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var fileTable: some View {
        if files.isEmpty {
            empty(saver.kind == .aerial
                  ? "Aerial assets are downloaded by the system into ~/Library/Application Support/com.apple.wallpaper/aerials/videos when used."
                  : "No files found inside this bundle.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Path").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Kind").frame(width: 60, alignment: .leading)
                    Text("Size").frame(width: 80, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            HStack(spacing: 8) {
                                Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                                    .font(.caption)
                                    .foregroundStyle(file.isDirectory ? .blue : .secondary)
                                Text(file.relativePath.wrappable)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(file.isDirectory ? "Folder" : "File")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60, alignment: .leading)
                                Text(file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 80, alignment: .trailing)
                            }
                            .font(.callout)
                            .padding(.vertical, 3)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: Info

    @ViewBuilder
    private var infoTable: some View {
        if saver.infoEntries.isEmpty {
            empty("No metadata could be read for this item.")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(sourceLine).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(saver.infoEntries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.key)
                                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(entry.value.wrappable)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var sourceLine: String {
        switch saver.kind {
        case .plugin, .provider: return "Contents/Info.plist — \(saver.infoEntries.count) keys"
        case .aerial: return "Aerial manifest entry (entries.json) — \(saver.infoEntries.count) fields"
        }
    }

    // MARK: Preferences

    private var prefsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if saver.kind == .aerial {
                    prefSection(
                        title: "Selected Aerial configuration",
                        groups: [],
                        emptyMessage: "Aerial videos are chosen in System Settings through the Aerial category; the current choice is shown under “Wallpaper store” below (scope · Idle = screen saver)."
                    )
                } else {
                    prefSection(
                        title: "\(saver.name) — module preferences",
                        groups: moduleGroups,
                        emptyMessage: saver.kind == .provider
                            ? "No extension preferences stored yet."
                            : "This module has not stored any preferences yet.\nClick “Open configuration…”, change a setting and press OK, then press Reload."
                    )
                }

                prefSection(
                    title: "Wallpaper store — screen saver & desktop choices",
                    groups: storeGroups,
                    emptyMessage: "No wallpaper store entries found (macOS 14 and later keeps the screen saver choice here)."
                )

                prefSection(
                    title: "Screen saver engine (com.apple.screensaver)",
                    groups: systemGroups,
                    emptyMessage: "The legacy screen saver engine has no stored settings."
                )

                if moduleGroups.isEmpty && saver.kind == .plugin {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Locations searched").font(.caption).foregroundStyle(.secondary)
                        ForEach(PreferencesReader.searchedLocations(for: saver.bundleID), id: \.self) { path in
                            Text(PreferencesReader.abbreviate(path))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        reload()
                    } label: {
                        Label("Reload preferences", systemImage: "arrow.clockwise")
                    }
                    if saver.kind != .aerial {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: WallpaperStore.indexPath)])
                        } label: {
                            Label("Reveal wallpaper store", systemImage: "folder")
                        }
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func prefSection(title: String, groups: [PrefGroup], emptyMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if groups.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(group.title).font(.callout).fontWeight(.medium)
                            Text(group.pathLabel)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if group.entries.isEmpty {
                            Text("File exists but contains no keys.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(group.entries) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.key)
                                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                                        .textSelection(.enabled)
                                    Text(entry.value.wrappable)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(nsColor: .textBackgroundColor).opacity(0.7))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func empty(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

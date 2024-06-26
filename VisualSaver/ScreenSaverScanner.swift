import Foundation

struct InfoEntry: Identifiable, Hashable {
    let id: String
    let key: String
    let value: String
}

/// What kind of screen saver an item is.
enum SaverKind: String, CaseIterable {
    case plugin     // classic .saver bundle loaded through the ScreenSaver framework
    case provider   // ExtensionKit wallpaper/screen-saver provider (.appex)
    case aerial     // individual Aerial video asset (Aerial screen saver)

    var symbolName: String {
        switch self {
        case .plugin: return "sparkles.tv"
        case .provider: return "square.stack.3d.up.fill"
        case .aerial: return "film"
        }
    }

    func sectionTitle(count: Int) -> String {
        switch self {
        case .plugin: return "Screen savers (.saver) — \(count)"
        case .provider: return "Built-in providers — \(count)"
        case .aerial: return "Aerial videos — \(count)"
        }
    }
}

struct ScreenSaverBundle: Identifiable {
    let id: URL
    let kind: SaverKind
    let name: String
    /// Second line in the sidebar: the bundle id, or the category for Aerial assets.
    let subtitle: String
    let bundleID: String
    let version: String
    let principalClass: String
    let size: Int64
    let isSystem: Bool
    let location: String
    let infoEntries: [InfoEntry]
    let providerID: String?
    let assetID: String?
    let shotID: String
    let categoryNames: String
    let thumbnail: URL?
    let video: URL?
    let remotePreview: URL?
    /// Set when the bundle cannot run (for example it was never built), with a
    /// human readable explanation.
    var issue: String? = nil

    var isBroken: Bool { issue != nil }

    var sizeLabel: String {
        size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "—"
    }

    var locationLabel: String { PreferencesReader.abbreviate(location) }

    var isActive: Bool { ScreenSaverScanner.activeMatch(id: id, assetID: assetID, providerID: providerID) }

    var badgeText: String {
        if isBroken { return "Cannot run" }
        switch kind {
        case .plugin: return isSystem ? "System" : "Local"
        case .provider: return "Built-in"
        case .aerial: return video != nil ? "Downloaded" : "Remote"
        }
    }

    /// Rows shown in the detail header, per kind.
    var headerRows: [(String, String)] {
        switch kind {
        case .plugin:
            return [("Version", version), ("Size on disk", sizeLabel),
                    ("Principal class", principalClass), ("Location", locationLabel)]
        case .provider:
            return [("Version", version), ("Type", "ExtensionKit provider"),
                    ("Extension point", WallpaperCatalog.providerPoint), ("Location", locationLabel)]
        case .aerial:
            return [("Asset ID", assetID ?? "—"), ("Shot", shotID),
                    ("Category", categoryNames), ("Video", video != nil ? sizeLabel + " downloaded" : "not downloaded")]
        }
    }
}

struct SaverFile: Identifiable, Hashable {
    let id: String
    let relativePath: String
    let isDirectory: Bool
    let size: Int64?
}

@MainActor
final class ScreenSaverScanner: ObservableObject {
    @Published var bundles: [ScreenSaverBundle] = []
    @Published var isScanning = false

    /// The screen saver the system is currently configured to show (either a
    /// legacy `moduleDict` entry or the wallpaper store's idle choice).
    nonisolated(unsafe) static var activePluginPath: String?
    nonisolated(unsafe) static var activeAssetID: String?
    nonisolated(unsafe) static var activeProviderID: String?

    nonisolated static func locations() -> [String] {
        var paths = [
            "/System/Library/Screen Savers",
            "/Library/Screen Savers",
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Screen Savers"),
        ]
        let apps = NSSearchPathForDirectoriesInDomains(.applicationDirectory, [.allDomainsMask], true)
        for app in apps {
            paths.append((app as NSString).appendingPathComponent("Contents/Library/Screen Savers"))
        }
        return paths
    }

    func scan() {
        isScanning = true
        Self.refreshActiveSelection()

        var found = Self.pluginBundles()
        found += WallpaperCatalog.providers()
        found += WallpaperCatalog.aerialAssets()

        bundles = found.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        isScanning = false
    }

    nonisolated static func refreshActiveSelection() {
        activePluginPath = nil
        activeAssetID = nil
        activeProviderID = nil

        if let legacy = PreferencesReader.activeModule() { activePluginPath = legacy.path }
        if let current = WallpaperStore.activeScreenSaver() {
            activeProviderID = current.provider
            if let path = current.modulePath { activePluginPath = path }
            if let asset = current.assetID { activeAssetID = asset }
        }
    }

    nonisolated static func activeMatch(id: URL, assetID: String?, providerID: String?) -> Bool {
        if let assetID, activeAssetID == assetID { return true }
        if let providerID, activeProviderID == providerID, assetID == nil { return true }
        if let activePluginPath {
            return id.path == activePluginPath || id.resolvingSymlinksInPath().path == activePluginPath
        }
        return false
    }

    // MARK: - Classic .saver plugins

    nonisolated static func pluginBundles() -> [ScreenSaverBundle] {
        var found: [ScreenSaverBundle] = []
        for root in locations() {
            let rootURL = URL(fileURLWithPath: root)
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            for case let item as URL in enumerator {
                guard item.pathExtension.lowercased() == "saver" else { continue }
                if let bundle = describePlugin(item) { found.append(bundle) }
                enumerator.skipDescendants()
            }
        }
        return found
    }

    nonisolated static func describePlugin(_ url: URL) -> ScreenSaverBundle? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: infoURL.path) else { return nil }
        let info = readPlist(infoURL)

        func string(_ key: String) -> String? {
            if let value = info[key] as? String { return value }
            if let value = info[key] as? NSNumber { return value.stringValue }
            return nil
        }

        let lastComponent = url.lastPathComponent
        let trimmedName = lastComponent.lowercased().hasSuffix(".saver")
            ? String(lastComponent.dropLast(".saver".count))
            : lastComponent
        let rawBundleID = string("CFBundleIdentifier") ?? "—"
        let problem = issue(for: url, info: info)

        var subtitle = expandable(rawBundleID) ? "no bundle identifier" : rawBundleID
        if problem != nil { subtitle += " · cannot run" }

        return ScreenSaverBundle(
            id: url,
            kind: .plugin,
            name: plainName(string("CFBundleName"), fallback: trimmedName),
            subtitle: subtitle,
            bundleID: expandable(rawBundleID) ? "—" : rawBundleID,
            version: plainName(string("CFBundleShortVersionString") ?? string("CFBundleVersion"), fallback: "—"),
            principalClass: plainName(string("NSPrincipalClass"), fallback: "—"),
            size: bundleSize(of: url),
            isSystem: url.path.hasPrefix("/System/") || url.path.hasPrefix("/Library/"),
            location: url.deletingLastPathComponent().path,
            infoEntries: info.keys.sorted().map {
                InfoEntry(id: $0, key: $0, value: ValueFormatter.describe(info[$0]!))
            },
            providerID: nil,
            assetID: nil,
            shotID: "—",
            categoryNames: "—",
            thumbnail: nil,
            video: nil,
            remotePreview: nil,
            issue: problem
        )
    }

    /// `true` when a value still contains unexpanded Xcode build settings such
    /// as `$(PRODUCT_NAME)`, which means the bundle was never built properly.
    nonisolated static func expandable(_ value: String) -> Bool {
        value.contains("$(") || value.contains("${")
    }

    /// A value that is safe to show, falling back when it is empty or a raw
    /// build setting (`$(PRODUCT_NAME)` and friends).
    nonisolated static func plainName(_ value: String?, fallback: String) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty, !expandable(value) else {
            return fallback
        }
        return value
    }

    /// Explains why a bundle cannot run, or `nil` when it looks runnable.
    nonisolated static func issue(for url: URL, info: [String: Any]) -> String? {
        let declared = info["CFBundleExecutable"] as? String
        let macosPath = url.appendingPathComponent("Contents/MacOS").path
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: macosPath)) ?? []

        if let declared, expandable(declared) || contents.isEmpty {
            return "This bundle was copied before it was built: CFBundleExecutable is still “\(declared)” and Contents/MacOS is empty, so there is no code to run. macOS cannot use it as a screen saver either. Add the built .saver (or copy the .saver out of Xcode's Products folder) to use it."
        }
        guard let declared else {
            return "Info.plist has no CFBundleExecutable, so there is no code to run."
        }
        let executable = url.appendingPathComponent("Contents/MacOS/\(declared)")
        if !FileManager.default.fileExists(atPath: executable.path) {
            return "The executable “\(declared)” listed in Info.plist is missing from Contents/MacOS (\(contents.isEmpty ? "the folder is empty" : contents.joined(separator: ", ")))."
        }
        if contents.isEmpty {
            return "Contents/MacOS is empty, so there is no code to run."
        }
        return nil
    }

    /// Real on-disk size of the bundle (recursive) — not the directory entry size.
    nonisolated static func bundleSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    nonisolated static func contents(of bundle: URL) -> [SaverFile] {
        var output: [SaverFile] = []
        guard let enumerator = FileManager.default.enumerator(
            at: bundle,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return output }

        let basePath = bundle.path
        for case let item as URL in enumerator {
            let relative = item.path.hasPrefix(basePath + "/")
                ? String(item.path.dropFirst(basePath.count + 1))
                : item.lastPathComponent

            if relative.hasPrefix("_CodeSignature") { continue }

            let resource = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            output.append(
                SaverFile(
                    id: relative,
                    relativePath: relative,
                    isDirectory: resource?.isDirectory ?? false,
                    size: resource?.fileSize.map { Int64($0) }
                )
            )
        }
        return output.sorted { $0.relativePath < $1.relativePath }
    }

    nonisolated static func readPlist(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            return (NSDictionary(contentsOf: url) as? [String: Any]) ?? [:]
        }
        return dict
    }
}

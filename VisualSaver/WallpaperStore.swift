import Foundation

/// Reads the modern wallpaper store, which is where macOS 14+ keeps the
/// *actual* configuration of built-in screen savers: each scope has a
/// "Desktop" and an "Idle" role, and "Idle" **is** the screen saver.
///
///   ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist
///
/// `Configuration` and `EncodedOptionValues` are nested binary plists, so they
/// are decoded and shown key by key.
enum WallpaperStore {

    static var indexPath: String {
        NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
    }

    private static var index: [String: Any] {
        ScreenSaverScanner.readPlist(URL(fileURLWithPath: indexPath))
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: indexPath) }

    // MARK: - Groups for the Preferences tab

    static func groups() -> [PrefGroup] {
        let root = index
        guard !root.isEmpty else { return [] }

        var groups: [PrefGroup] = []
        for scope in ["AllSpacesAndDisplays", "SystemDefault"] {
            guard let scopeDict = root[scope] as? [String: Any] else { continue }
            for role in ["Idle", "Desktop"] {
                guard let roleDict = scopeDict[role] as? [String: Any] else { continue }
                let title = "\(scopeLabel(scope)) · \(role == "Idle" ? "Idle (screen saver)" : "Desktop wallpaper")"
                var entries: [PrefEntry] = []

                if let content = roleDict["Content"] as? [String: Any] {
                    let choices = content["Choices"] as? [[String: Any]] ?? []
                    for (position, choice) in choices.enumerated() {
                        let prefix = choices.count > 1 ? "Choice \(position + 1) · " : ""
                        append(&entries, "\(prefix)Provider", choice["Provider"], group: scope + role)
                        if let configuration = decode(choice["Configuration"]) {
                            append(&entries, "\(prefix)Configuration", configuration, group: scope + role)
                        }
                        if let options = decode(choice["EncodedOptionValues"]) {
                            append(&entries, "\(prefix)EncodedOptionValues", options, group: scope + role)
                        }
                        if let files = choice["Files"] as? [String], !files.isEmpty {
                            append(&entries, "\(prefix)Files", files.joined(separator: "\n"), group: scope + role)
                        }
                    }
                    if let shuffle = content["Shuffle"] as? [String: Any] {
                        append(&entries, "Shuffle (screen saver)", shuffle["ScreenSaver"], group: scope + role)
                        append(&entries, "Shuffle (desktop)", shuffle["Desktop"], group: scope + role)
                    }
                }
                append(&entries, "LastSet", roleDict["LastSet"], group: scope + role)
                append(&entries, "LastUse", roleDict["LastUse"], group: scope + role)
                if !entries.isEmpty {
                    groups.append(PrefGroup(id: "\(indexPath)#\(scope)#\(role)", title: title,
                                            path: indexPath, exists: true, entries: entries))
                }
            }
        }
        return groups
    }

    // MARK: - Active screen saver

    /// The idle (screen saver) choice currently in effect.
    static func activeScreenSaver() -> (provider: String, modulePath: String?, assetID: String?)? {
        let root = index
        for scope in ["AllSpacesAndDisplays", "SystemDefault"] {
            guard let idle = (root[scope] as? [String: Any])?["Idle"] as? [String: Any],
                  let choices = (idle["Content"] as? [String: Any])?["Choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let provider = choice["Provider"] as? String else { continue }

            let configuration = decode(choice["Configuration"])
            var modulePath: String?
            if let module = (configuration as? [String: Any])?["module"] as? [String: Any],
               let relative = module["relative"] as? String {
                modulePath = URL(string: relative)?.path ?? relative.replacingOccurrences(of: "file://", with: "")
            }
            return (provider, modulePath, findAssetID(in: configuration))
        }
        return nil
    }

    /// Looks for an aerial asset id anywhere inside the configuration.
    private static func findAssetID(in value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string.range(of: #"^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil
                ? string : nil
        }
        if let array = value as? [Any] {
            for element in array { if let found = findAssetID(in: element) { return found } }
            return nil
        }
        if let dict = value as? [String: Any] {
            for key in dict.keys.sorted() where key.lowercased().contains("asset") {
                if let found = findAssetID(in: dict[key]) { return found }
            }
            for element in dict.values { if let found = findAssetID(in: element) { return found } }
        }
        return nil
    }

    // MARK: - Helpers

    static func decode(_ value: Any?) -> Any? {
        guard let data = value as? Data else { return value }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    private static func append(_ entries: inout [PrefEntry], _ key: String, _ value: Any?, group: String) {
        guard let value, !(value is NSNull) else { return }
        let rendered = ValueFormatter.describe(value)
        guard !rendered.isEmpty else { return }
        entries.append(PrefEntry(id: group + "::" + key, key: key, value: rendered))
    }

    private static func scopeLabel(_ scope: String) -> String {
        scope == "SystemDefault" ? "System default" : "All spaces & displays"
    }
}

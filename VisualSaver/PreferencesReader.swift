import Foundation

struct PrefEntry: Identifiable, Hashable {
    let id: String
    let key: String
    let value: String
}

/// One preferences file (domain) that could hold a screen saver's settings.
struct PrefGroup: Identifiable {
    let id: String
    let title: String
    let path: String
    let exists: Bool
    let entries: [PrefEntry]

    var pathLabel: String { PreferencesReader.abbreviate(path) }
}

enum PreferencesReader {

    // MARK: - Locations

    private static var home: String { NSHomeDirectory() }
    private static var preferencesDir: String { home + "/Library/Preferences" }
    private static var byHostDir: String { preferencesDir + "/ByHost" }

    static let systemDomain = "com.apple.screensaver"

    // MARK: - Module preferences

    /// Every preferences file that plausibly belongs to this module, in
    /// priority order: exact domain match first, then files whose name
    /// mentions the module (screen savers are free to pick any domain).
    static func moduleGroups(bundleID: String, displayName: String) -> [PrefGroup] {
        var groups: [PrefGroup] = []
        var seen = Set<String>()

        func add(_ path: String, title: String) {
            guard !seen.contains(path) else { return }
            seen.insert(path)
            groups.append(
                PrefGroup(
                    id: path,
                    title: title,
                    path: path,
                    exists: FileManager.default.fileExists(atPath: path),
                    entries: readEntries(file: path)
                )
            )
        }

        // 1. Exact domain: ~/Library/Preferences/<bundleID>.plist
        for file in files(in: preferencesDir, where: { $0.matches(domain: bundleID) }) {
            add(file, title: "Module domain")
        }
        // 2. Exact domain per host: ~/Library/Preferences/ByHost/<bundleID>.<uuid>.plist
        for file in files(in: byHostDir, where: { $0.matches(domain: bundleID) }) {
            add(file, title: "Module domain (per host)")
        }
        // 3. Heuristic: any preference file that mentions the module name.
        let tail = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        for needle in [tail, displayName].filter({ $0.count >= 5 }) {
            for directory in [preferencesDir, byHostDir] {
                for file in files(in: directory, where: { $0.lowercased().contains(needle.lowercased()) }).prefix(3) {
                    add(file, title: "Matched by name “\(needle)”")
                }
            }
        }
        return groups
    }

    /// Files that were searched but do not exist yet — shown so an empty
    /// Preferences tab is obviously "not saved yet" rather than broken.
    static func searchedLocations(for bundleID: String) -> [String] {
        [preferencesDir + "/\(bundleID).plist",
         byHostDir + "/\(bundleID).<host-id>.plist"]
    }

    // MARK: - Extension (provider) preferences

    /// Wallpaper/screen-saver extensions keep their settings inside their
    /// sandbox container instead of the user's preference directory.
    static func containerGroups(bundleID: String) -> [PrefGroup] {
        let container = home + "/Library/Containers/\(bundleID)/Data/Library/Preferences"
        var groups: [PrefGroup] = []
        for directory in [container, container + "/ByHost"] {
            for file in files(in: directory, where: { _ in true }) {
                groups.append(PrefGroup(id: file, title: "Extension preferences", path: file,
                                        exists: true, entries: readEntries(file: file)))
            }
        }
        return groups
    }

    // MARK: - System preferences

    static func systemGroups() -> [PrefGroup] {
        var groups: [PrefGroup] = []
        for file in files(in: preferencesDir, where: { $0.matches(domain: systemDomain) }) {
            groups.append(PrefGroup(id: file, title: "Screen saver engine", path: file,
                                    exists: true, entries: readEntries(file: file)))
        }
        for file in files(in: byHostDir, where: { $0.matches(domain: systemDomain) }) {
            groups.append(PrefGroup(id: file, title: "Screen saver engine (per host)", path: file,
                                    exists: true, entries: readEntries(file: file)))
        }
        return groups
    }

    /// The module currently selected in System Settings, read from the
    /// engine's `moduleDict` (`moduleName`, `path`, `type`).
    static func activeModule() -> (name: String, path: String)? {
        for group in systemGroups() {
            guard let dict = read(file: group.path),
                  let module = dict["moduleDict"] as? [String: Any],
                  let name = module["moduleName"] as? String else { continue }
            return (name, module["path"] as? String ?? "")
        }
        return nil
    }

    // MARK: - Plist reading

    static func read(file: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else { return nil }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            if let dict = plist as? [String: Any] { return dict }
        }
        return NSDictionary(contentsOfFile: file) as? [String: Any]
    }

    private static func readEntries(file: String) -> [PrefEntry] {
        guard let dict = read(file: file) else { return [] }
        return dict.keys.sorted().map { key in
            PrefEntry(id: file + "::" + key, key: key, value: ValueFormatter.describe(dict[key]!))
        }
    }

    // MARK: - Helpers

    private static func files(in directory: String, where predicate: (String) -> Bool) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return items
            .filter { $0.hasSuffix(".plist") && !$0.hasPrefix(".") }
            .filter { !$0.hasPrefix("com.sid.visualsaver") } // never show our own app's prefs
            .filter(predicate)
            .sorted()
            .map { directory + "/" + $0 }
    }

    static func abbreviate(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private extension String {
    /// `com.apple.screensaver.8B2C-…` matches domain `com.apple.screensaver`,
    /// and `com.apple.screensaver.plist` matches too.
    func matches(domain: String) -> Bool {
        let name = lowercased()
        let domain = domain.lowercased()
        guard name.hasSuffix(".plist") else { return false }
        let stem = String(name.dropLast(".plist".count))
        return stem == domain || stem.hasPrefix(domain + ".")
    }
}

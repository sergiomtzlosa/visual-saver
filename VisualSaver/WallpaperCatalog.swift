import Foundation

/// Discovers the two kinds of screen savers that are *not* classic `.saver`
/// bundles on modern macOS:
///
///  * **Providers** — ExtensionKit extensions with the `com.apple.wallpaper`
///    extension point (`/System/Library/ExtensionKit/Extensions/*.appex`).
///    They are what System Settings uses to offer Aerial, Dynamic Desktop,
///    Gradients, Pictures, the per-release wallpapers and the legacy
///    `.saver` list.
///  * **Aerial assets** — the individual Aerial videos described in the
///    user's aerial manifest, with their local thumbnails/videos.
enum WallpaperCatalog {

    static let providerPoint = "com.apple.wallpaper"
    static let aerialsProviderID = "com.apple.wallpaper.extension.aerials"

    static var aerialsRoot: String {
        NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper/aerials"
    }

    static func providerSearchPaths() -> [String] {
        ["/System/Library/ExtensionKit/Extensions",
         "/Library/ExtensionKit/Extensions",
         NSHomeDirectory() + "/Library/ExtensionKit/Extensions"]
    }

    private static let friendlyNames: [String: String] = [
        "com.apple.wallpaper.extension.aerials": "Aerial",
        "com.apple.wallpaper.extension.dynamic": "Dynamic Desktop",
        "com.apple.wallpaper.extension.gradient": "Gradients",
        "com.apple.wallpaper.extension.image": "Pictures",
        "com.apple.wallpaper.extension.legacy": "Legacy Screen Savers",
        "com.apple.wallpaper.extension.macintosh": "Macintosh",
        "com.apple.wallpaper.extension.monterey": "Monterey",
        "com.apple.wallpaper.extension.sequoia": "Sequoia",
        "com.apple.wallpaper.extension.sonoma": "Sonoma",
        "com.apple.wallpaper.extension.ventura": "Ventura",
        "com.apple.NeptuneOneExtension": "Neptune One",
    ]

    // MARK: - Built-in providers

    static func providers() -> [ScreenSaverBundle] {
        var found: [ScreenSaverBundle] = []
        for root in providerSearchPaths() {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for item in items.sorted() where item.hasSuffix(".appex") {
                let url = URL(fileURLWithPath: root).appendingPathComponent(item)
                let info = ScreenSaverScanner.readPlist(url.appendingPathComponent("Contents/Info.plist"))
                guard let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
                      attributes["EXExtensionPointIdentifier"] as? String == providerPoint else { continue }

                let bundleID = info["CFBundleIdentifier"] as? String ?? item
                found.append(
                    ScreenSaverBundle(
                        id: url,
                        kind: .provider,
                        name: friendlyNames[bundleID] ?? (info["CFBundleDisplayName"] as? String) ?? item,
                        subtitle: "Provides built-in screen savers",
                        bundleID: bundleID,
                        version: info["CFBundleShortVersionString"] as? String ?? "—",
                        principalClass: "—",
                        size: ScreenSaverScanner.bundleSize(of: url),
                        isSystem: url.path.hasPrefix("/System/") || url.path.hasPrefix("/Library/"),
                        location: root,
                        infoEntries: info.keys.sorted().map {
                            InfoEntry(id: $0, key: $0, value: ValueFormatter.describe(info[$0]!))
                        },
                        providerID: bundleID,
                        assetID: nil,
                        shotID: "—",
                        categoryNames: "—",
                        thumbnail: nil,
                        video: nil,
                        remotePreview: nil
                    )
                )
            }
        }
        return found
    }

    // MARK: - Aerial assets

    static func aerialAssets() -> [ScreenSaverBundle] {
        let manifestURL = URL(fileURLWithPath: aerialsRoot + "/manifest/entries.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else { return [] }

        let strings = localizations()
        var categoryNames: [String: String] = [:]
        var subcategoryNames: [String: String] = [:]
        for category in json["categories"] as? [[String: Any]] ?? [] {
            if let id = category["id"] as? String, let key = category["localizedNameKey"] as? String {
                categoryNames[id] = strings[key] ?? prettify(key)
            }
            for subcategory in category["subcategories"] as? [[String: Any]] ?? [] {
                if let id = subcategory["id"] as? String, let key = subcategory["localizedNameKey"] as? String {
                    subcategoryNames[id] = strings[key] ?? prettify(key)
                }
            }
        }

        let thumbnailsDir = aerialsRoot + "/thumbnails"
        let videosDir = aerialsRoot + "/videos"

        return assets.compactMap { asset -> ScreenSaverBundle? in
            guard let assetID = asset["id"] as? String else { return nil }

            let nameKey = asset["localizedNameKey"] as? String ?? ""
            var name = strings[nameKey] ?? prettify(nameKey)

            let variant = asset["variant"] as? [String: Any]
            let appearance = variant?["appearance"] as? String
            let categories = (asset["categories"] as? [String] ?? []).compactMap { categoryNames[$0] }
            let subcategories = (asset["subcategories"] as? [String] ?? []).compactMap { subcategoryNames[$0] }

            // Dynamic-wallpaper entries share a name ("Light"/"Dark") — make them unique.
            if appearance == "light" || appearance == "dark" {
                let pretty = appearance == "light" ? "Light" : "Dark"
                if !name.lowercased().contains(pretty.lowercased()) { name += " (\(pretty))" }
            }

            let thumbnail = file(thumbnailsDir + "/\(assetID).png")
            let video = file(videosDir + "/\(assetID).mov") ?? file(videosDir + "/\(assetID).mp4")
            let remote = (asset["previewImage"] as? String).flatMap(URL.init(string:))

            var rows: [InfoEntry] = []
            func add(_ key: String, _ value: Any?) {
                guard let value, !(value is NSNull) else { return }
                rows.append(InfoEntry(id: key, key: key, value: ValueFormatter.describe(value)))
            }
            add("name (localised)", name)
            add("id", assetID)
            add("localizedNameKey", nameKey)
            add("shotID", asset["shotID"])
            add("accessibilityLabel", asset["accessibilityLabel"])
            add("categories", categories)
            add("subcategories", subcategories)
            add("categoryIDs", asset["categories"])
            add("preferredOrder", asset["preferredOrder"])
            add("showInTopLevel", asset["showInTopLevel"])
            add("includeInShuffle", asset["includeInShuffle"])
            add("variant", variant)
            add("videoGravity", asset["videoGravity"])
            add("pointsOfInterest", asset["pointsOfInterest"])
            add("previewImage", remote?.absoluteString)
            add("4K SDR video URL", asset["url-4K-SDR-240FPS"])
            add("downloaded video", video?.path ?? "not downloaded")
            add("local thumbnail", thumbnail?.path ?? "missing")

            let subtitleParts = categories + subcategories
            return ScreenSaverBundle(
                id: URL(fileURLWithPath: videosDir + "/\(assetID)"),
                kind: .aerial,
                name: name,
                subtitle: subtitleParts.isEmpty ? "Aerial" : subtitleParts.joined(separator: " · "),
                bundleID: aerialsProviderID,
                version: asset["shotID"] as? String ?? "—",
                principalClass: "—",
                size: video.flatMap { size(of: $0) } ?? 0,
                isSystem: true,
                location: aerialsRoot,
                infoEntries: rows,
                providerID: aerialsProviderID,
                assetID: assetID,
                shotID: asset["shotID"] as? String ?? "—",
                categoryNames: subtitleParts.isEmpty ? "Aerial" : subtitleParts.joined(separator: " · "),
                thumbnail: thumbnail,
                video: video,
                remotePreview: remote
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Localised names

    /// The aerial manifest ships a `.loctable` with every name in every
    /// language; prefer the user's language, then English.
    static func localizations() -> [String: String] {
        let path = aerialsRoot + "/manifest/TVIdleScreenStrings.bundle/Contents/Resources/Localizable.nocache.loctable"
        let table = ScreenSaverScanner.readPlist(URL(fileURLWithPath: path))
        guard !table.isEmpty else { return [:] }

        var languages: [String] = []
        if let code = Locale.current.language.languageCode?.identifier { languages.append(code) }
        for fallback in ["en", "en_US"] where !languages.contains(fallback) { languages.append(fallback) }

        for code in languages {
            if let strings = table[code] as? [String: String] { return strings }
        }
        for value in table.values {
            if let strings = value as? [String: String], !strings.isEmpty { return strings }
        }
        return [:]
    }

    /// Turns a localisation key such as `AerialSubcategoryGoldenGate` or
    /// `GG_A_SUNSET_NAME` into something readable when no string is available.
    static func prettify(_ key: String) -> String {
        var text = key
        for suffix in ["_NAME", "_KEY", "_DESCRIPTION"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        for prefix in ["AerialSubcategoryDescription", "AerialSubcategory", "AerialCategoryDescription", "AerialCategory"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        text = text.replacingOccurrences(of: "_", with: " ")
        var words: [String] = []
        var current = ""
        for character in text {
            if character.isUppercase, !current.isEmpty, let last = current.last, last.isLowercase || last.isNumber {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        let joined = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? key : joined
    }

    // MARK: - Helpers

    private static func file(_ path: String) -> URL? {
        FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }
}

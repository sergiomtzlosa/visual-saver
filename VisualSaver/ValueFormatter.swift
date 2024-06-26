import Foundation

/// Renders plist / preference values (including nested arrays, dictionaries,
/// booleans, dates and binary data) as readable, copyable text.
enum ValueFormatter {

    static func describe(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string

        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue

        case let date as Date:
            return Self.dateFormatter.string(from: date)

        case let data as Data:
            if let text = String(data: data, encoding: .utf8), text.isReadableText {
                return text
            }
            return "<\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)) of binary data>"

        case let array as [Any]:
            return array.enumerated()
                .map { "[\($0.offset)] \(indent(describe($0.element)))" }
                .joined(separator: "\n")

        case let dict as [String: Any]:
            guard !dict.isEmpty else { return "{}" }
            return dict.keys.sorted()
                .map { "\($0) = \(indent(describe(dict[$0]!)))" }
                .joined(separator: "\n")

        default:
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return "\(value)"
        }
    }

    private static func indent(_ text: String) -> String {        text.contains("\n") ? "\n" + text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    " + $0 }
            .joined(separator: "\n") : text
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

private extension String {
    var isReadableText: Bool {
        !isEmpty && !unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }
    }
}

extension String {
    /// Inserts zero-width spaces after separators so long paths, URLs and
    /// identifiers can wrap inside narrow panels (the characters are invisible,
    /// but they remove the text's huge minimum width, which is what forces
    /// windows to grow wider than the screen).
    var wrappable: String {
        guard count > 40 else { return self }
        let separators: Set<Character> = ["/", ".", "_", "-", "=", "&", "?", ":", "\\"]
        var out = ""
        out.reserveCapacity(count + count / 4)
        for character in self {
            out.append(character)
            if separators.contains(character) { out.append("\u{200B}") }
        }
        return out
    }
}

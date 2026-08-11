import Foundation

struct Replacement {
    var find: String
    var replace: String
}

class SettingsManager {
    static let shared = SettingsManager()

    private let settingsPath: String
    private var _replacements: [Replacement] = []
    private var _selectedMicUID: String = ""

    var replacements: [Replacement] {
        get { _replacements }
        set {
            _replacements = newValue
            save()
        }
    }

    var selectedMicUID: String {
        get { _selectedMicUID }
        set {
            _selectedMicUID = newValue
            save()
        }
    }

    private init() {
        settingsPath = NSString("~/.custom-wispr-settings.json").expandingTildeInPath
        load()
    }

    func applyReplacements(_ text: String) -> String {
        var result = text
        for r in _replacements {
            guard !r.find.isEmpty else { continue }
            result = result.replacingOccurrences(
                of: SettingsManager.wordBoundedPattern(for: r.find),
                with: NSRegularExpression.escapedTemplate(for: r.replace),
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    /// Rules match whole words only. A plain substring match lets a short rule fire
    /// inside unrelated words — `SW -> SoW` rewrote "answered" as "anSoWered", and the
    /// result reached the user's text field because find/replace runs before the LLM,
    /// which is told to preserve terms it doesn't recognise.
    ///
    /// `\b` asserts a word/non-word transition, so it only means anything next to a word
    /// character. A rule that starts or ends with punctuation (`"derigointeractive.com"`)
    /// gets no anchor on that side, or it could never match.
    static func wordBoundedPattern(for find: String) -> String {
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        let leading = find.first.map(isWordCharacter) == true ? "\\b" : ""
        let trailing = find.last.map(isWordCharacter) == true ? "\\b" : ""
        return leading + NSRegularExpression.escapedPattern(for: find) + trailing
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: settingsPath),
              let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let arr = json["replacements"] as? [[String: String]] {
            _replacements = arr.compactMap { dict in
                guard let find = dict["find"], let replace = dict["replace"] else { return nil }
                return Replacement(find: find, replace: replace)
            }
        }
        if let uid = json["selectedMicUID"] as? String {
            _selectedMicUID = uid
        }
    }

    private func save() {
        let arr = _replacements.map { ["find": $0.find, "replace": $0.replace] }
        let json: [String: Any] = [
            "replacements": arr,
            "selectedMicUID": _selectedMicUID
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else {
            log("ERROR: Failed to serialize settings")
            return
        }
        FileManager.default.createFile(atPath: settingsPath, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

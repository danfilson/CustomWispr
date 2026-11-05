import Foundation

struct Replacement {
    var find: String
    var replace: String
}

struct CleanupRule {
    var style: CleanupStyle
    var bundleIds: [String]
    var titleContains: [String]
    var urlContains: [String] = []
}

class SettingsManager {
    static let shared = SettingsManager()

    private let settingsPath: String
    private var _replacements: [Replacement] = []
    private var _selectedMicUID: String = ""
    private var _vocabulary: [String] = []
    private var _defaultStyle: CleanupStyle = .tidy
    private var _cleanupRules: [CleanupRule] = SettingsManager.defaultRules
    private var _styleOverride: String = "auto"
    private var _speakerContext: String = SettingsManager.defaultSpeakerContext

    private static let defaultRules: [CleanupRule] = [
        CleanupRule(style: .tidy, bundleIds: ["com.apple.mail", "com.microsoft.Outlook"], titleContains: []),
        CleanupRule(style: .tidy,
                    bundleIds: ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser"],
                    titleContains: [],
                    urlContains: ["mail.google.com", "outlook.office.com", "outlook.live.com"])
    ]
    private static let defaultSpeakerContext = "Daniel Filson runs Dirigo Interactive, a small agency doing web accessibility work (WCAG 2.2 AA, ADA Title II) for municipalities and regional councils in Maine such as GPCOG, SMPDC, and Biddeford. Tools often mentioned: HubSpot, Obsidian, Claude Code, CustomWispr, Krisp."

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

    /// Proper nouns passed to Whisper as a prompt. Edited in the JSON file only.
    var vocabulary: [String] {
        get { _vocabulary }
        set {
            _vocabulary = newValue
            save()
        }
    }

    /// "auto" (use profile rules), "verbatim" or "tidy" (force for every dictation).
    var cleanupStyleOverride: String {
        get { _styleOverride }
        set {
            _styleOverride = newValue
            save()
        }
    }

    /// Static background about the speaker, appended to the cleanup prompt when non-empty.
    var speakerContext: String { _speakerContext }

    /// Override wins; otherwise the first rule whose bundle id matches (and whose title
    /// filter, if any, matches case-insensitively) decides; otherwise the default style.
    /// Resolves the cleanup style for the frontmost app. A rule matches when the bundle id
    /// matches AND (no title/url terms are set, OR any title term is in the window title,
    /// OR any url term is in the focused tab's URL). Returns the matched rule index for logging.
    func resolveStyle(bundleId: String, windowTitle: String, windowURL: String = "") -> (style: CleanupStyle, rule: Int?) {
        if let forced = CleanupStyle(rawValue: _styleOverride) { return (forced, nil) }
        for (i, rule) in _cleanupRules.enumerated() where rule.bundleIds.contains(bundleId) {
            let unconstrained = rule.titleContains.isEmpty && rule.urlContains.isEmpty
            let titleHit = rule.titleContains.contains { windowTitle.range(of: $0, options: .caseInsensitive) != nil }
            let urlHit = rule.urlContains.contains { windowURL.range(of: $0, options: .caseInsensitive) != nil }
            if unconstrained || titleHit || urlHit { return (rule.style, i) }
        }
        return (_defaultStyle, nil)
    }

    /// For diagnostics: the first configured url term found in the URL, or nil. Lets the
    /// key-down log say "url matched mail.google.com" without ever logging arbitrary hosts.
    func urlRuleTerm(in url: String) -> String? {
        guard !url.isEmpty else { return nil }
        for rule in _cleanupRules {
            if let term = rule.urlContains.first(where: { url.range(of: $0, options: .caseInsensitive) != nil }) { return term }
        }
        return nil
    }

    /// Whisper keeps only the last 224 prompt tokens, so the glossary is capped and
    /// cut at a term boundary. Falls back to the replacement targets when no vocabulary is set.
    func whisperGlossary(maxChars: Int = 300) -> (text: String, terms: Int) {
        var source = _vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if source.isEmpty {
            var seen = Set<String>()
            source = _replacements.map { $0.replace.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        var used: [String] = []
        var length = 1 // trailing period
        for term in source {
            let added = term.count + (used.isEmpty ? 0 : 2)
            if length + added > maxChars { break }
            used.append(term)
            length += added
        }
        guard !used.isEmpty else { return ("", 0) }
        return (used.joined(separator: ", ") + ".", used.count)
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
        if let vocab = json["vocabulary"] as? [String] {
            _vocabulary = vocab
        }
        if let profiles = json["cleanupProfiles"] as? [String: Any] {
            if let def = (profiles["default"] as? String).flatMap(CleanupStyle.init(rawValue:)) {
                _defaultStyle = def
            }
            if let rules = profiles["rules"] as? [[String: Any]] {
                _cleanupRules = rules.compactMap { dict in
                    guard let style = (dict["style"] as? String).flatMap(CleanupStyle.init(rawValue:)) else { return nil }
                    return CleanupRule(style: style,
                                       bundleIds: dict["bundleIds"] as? [String] ?? [],
                                       titleContains: dict["titleContains"] as? [String] ?? [],
                                       urlContains: dict["urlContains"] as? [String] ?? [])
                }
            }
        }
        if let override = json["cleanupStyleOverride"] as? String {
            _styleOverride = override
        }
        if let context = json["speakerContext"] as? String {
            _speakerContext = context
        }
        // Write defaults for any key the file doesn't have yet
        if json["cleanupProfiles"] == nil || json["cleanupStyleOverride"] == nil || json["speakerContext"] == nil {
            save()
        }
    }

    private func save() {
        let arr = _replacements.map { ["find": $0.find, "replace": $0.replace] }
        let json: [String: Any] = [
            "replacements": arr,
            "selectedMicUID": _selectedMicUID,
            "vocabulary": _vocabulary,
            "cleanupProfiles": [
                "default": _defaultStyle.rawValue,
                "rules": _cleanupRules.map {
                    ["style": $0.style.rawValue, "bundleIds": $0.bundleIds, "titleContains": $0.titleContains, "urlContains": $0.urlContains] as [String: Any]
                }
            ] as [String: Any],
            "cleanupStyleOverride": _styleOverride,
            "speakerContext": _speakerContext
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else {
            log("ERROR: Failed to serialize settings")
            return
        }
        FileManager.default.createFile(atPath: settingsPath, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

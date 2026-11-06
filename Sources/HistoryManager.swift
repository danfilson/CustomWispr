import Foundation

/// Per-dictation pipeline facts, recorded so a bad output can be traced to a stage after
/// the fact (which app, which style and model, what context was in the prompt, how long
/// each step took). Diagnostics only: never the window title or URL.
struct DictationMeta: Codable {
    var app: String?              // frontmost app bundle id at key-down
    var rule: Int?                // cleanupProfiles rule index that matched, if any
    var styleOverride: String?    // menu-bar override at the time (auto / verbatim / tidy)
    var cleanupMode: String?      // off / local / cloud
    var model: String?            // cleanup model id (nil when cleanup is off)
    var usedLLM: Bool?            // false when the text was too short for a round trip
    var promptChars: Int?         // system prompt length incl. speaker context
    var contextChars: Int?        // speakerContext length
    var contextHash: String?      // short hash of speakerContext, to tell versions apart
    var glossaryTerms: Int?       // whisper glossary terms in the prompt
    var replacementRules: Int?    // find/replace rules active
    var hesitationNormalized: Int?
    var chunks: Int?
    var recordingSec: Double?     // key-down to end of tail
    var whisperWaitSec: Double?   // end of tail to raw text ready (what the user waits for)
    var cleanupSec: Double?
    var totalSec: Double?         // end of tail to paste
    var warmUp: String?           // outcome of the key-down warm-up ("done 1.2s", "skipped (recent)", "failed", "none")
    var fallbackReason: String?   // non-nil when cleanup fell back to raw text
    var appVersion: String?
    var cachedTokens: Int?        // prompt tokens served from the provider's cache (since 2026-11-06)
    var cacheWriteTokens: Int?
    var costUSD: Double?          // this call's cost as reported by OpenRouter
}

/// Daniel's own note on a dictation, entered via F6. The correction signal the rest of the
/// improvement loop (monthly check, harness) learns from.
struct DictationFeedback: Codable {
    let timestamp: Date
    var tags: [String]
    var note: String
    var correctedText: String?
}

struct HistoryEntry: Codable {
    let id: UUID
    let timestamp: Date
    let cleanedText: String
    let rawText: String?
    let style: String?
    var meta: DictationMeta?
    var feedback: DictationFeedback?
}

class HistoryManager {
    static let shared = HistoryManager()

    private let filePath = NSString("~/.custom-wispr-history.json").expandingTildeInPath
    private let queue = DispatchQueue(label: "com.customwispr.history")
    /// Raised from 500 on 2026-08-11. The monthly health check reads this file as its only
    /// longitudinal data source, and at ~320 dictations/month a 500-entry cap held barely six
    /// weeks — month-over-month comparisons were losing their tail faster than they were
    /// gaining a head. 2000 entries is roughly six months and ~2.4 MB.
    /// Note: `HistorySuggester` deliberately samples only the newest 500 of these; that bound
    /// is about LLM input cost, not about how much history is worth keeping.
    private let maxEntries = 2000

    private var _entries: [HistoryEntry] = []

    var entries: [HistoryEntry] {
        queue.sync { _entries }
    }

    private init() {
        _entries = loadFromDisk()
    }

    @discardableResult
    func addEntry(cleanedText: String, rawText: String?, style: String? = nil, meta: DictationMeta? = nil) -> UUID {
        let entry = HistoryEntry(
            id: UUID(),
            timestamp: Date(),
            cleanedText: cleanedText,
            rawText: rawText,
            style: style,
            meta: meta,
            feedback: nil
        )
        queue.sync {
            _entries.insert(entry, at: 0)
            if _entries.count > maxEntries {
                _entries = Array(_entries.prefix(maxEntries))
            }
            saveToDisk()
        }
        return entry.id
    }

    /// Attaches (or replaces) feedback on an entry. Returns false if the id is unknown.
    @discardableResult
    func setFeedback(id: UUID, feedback: DictationFeedback) -> Bool {
        queue.sync {
            guard let i = _entries.firstIndex(where: { $0.id == id }) else { return false }
            _entries[i].feedback = feedback
            saveToDisk()
            return true
        }
    }

    func clearHistory() {
        queue.sync {
            _entries = []
            saveToDisk()
        }
    }

    func reload() {
        queue.sync {
            _entries = loadFromDisk()
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() -> [HistoryEntry] {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        guard let data = try? encoder.encode(_entries) else { return }

        let fm = FileManager.default
        do {
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath)
        } catch {
            fputs("[ERROR] Failed to save history: \(error.localizedDescription)\n", stderr)
        }
    }
}

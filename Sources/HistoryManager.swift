import Foundation

struct HistoryEntry: Codable {
    let id: UUID
    let timestamp: Date
    let cleanedText: String
    let rawText: String?
    let style: String?
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

    func addEntry(cleanedText: String, rawText: String?, style: String? = nil) {
        queue.sync {
            let entry = HistoryEntry(
                id: UUID(),
                timestamp: Date(),
                cleanedText: cleanedText,
                rawText: rawText,
                style: style
            )
            _entries.insert(entry, at: 0)
            if _entries.count > maxEntries {
                _entries = Array(_entries.prefix(maxEntries))
            }
            saveToDisk()
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

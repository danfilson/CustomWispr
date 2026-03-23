import Foundation

struct HistoryEntry: Codable {
    let id: UUID
    let timestamp: Date
    let cleanedText: String
    let rawText: String?
}

class HistoryManager {
    static let shared = HistoryManager()

    private let filePath = NSString("~/.custom-wispr-history.json").expandingTildeInPath
    private let queue = DispatchQueue(label: "com.customwispr.history")
    private let maxEntries = 500

    private var _entries: [HistoryEntry] = []

    var entries: [HistoryEntry] {
        queue.sync { _entries }
    }

    private init() {
        _entries = loadFromDisk()
    }

    func addEntry(cleanedText: String, rawText: String?) {
        queue.sync {
            let entry = HistoryEntry(
                id: UUID(),
                timestamp: Date(),
                cleanedText: cleanedText,
                rawText: rawText
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

import Foundation

struct ReplacementCandidate {
    let find: String
    let replace: String
    let occurrences: Int
    let confidence: Confidence
    let evidence: String
    enum Confidence { case high, low }
}

/// Analyzes transcription history to surface candidate find/replace rules via local pre-filtering + a single LLM batch call.
class HistorySuggester {

    enum SuggesterError: Error {
        case historyUnreadable
        case invalidURL
        case apiError(String)
        case parseError
    }

    private static let historyPath = NSString("~/.custom-wispr-history.json").expandingTildeInPath
    private static let settingsPath = NSString("~/.custom-wispr-settings.json").expandingTildeInPath
    private static let rejectedPath = NSString("~/.custom-wispr-suggestions-rejected.json").expandingTildeInPath

    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "is", "it", "in", "on", "at",
        "to", "of", "for", "with", "as", "by", "from", "that", "this", "was",
        "are", "be", "been", "being", "have", "has", "had", "do", "does", "did",
        "will", "would", "could", "should", "may", "might", "not", "no", "so",
        "if", "up", "out", "you", "i", "we", "he", "she", "they", "my", "your",
        "its", "our", "their", "what", "which", "who", "how", "when", "where"
    ]

    static func analyze() async throws -> (high: [ReplacementCandidate], low: [ReplacementCandidate]) {
        let entries = loadHistory()
        guard !entries.isEmpty else { return (high: [], low: []) }

        let existingFinds = loadExistingFinds()
        let rejectedPairs = loadRejectedPairs()

        let diffs = buildDiffs(from: entries)
        let excerpts = selectExcerpts(from: diffs, existingFinds: existingFinds, rejectedPairs: rejectedPairs)

        guard !excerpts.isEmpty else { return (high: [], low: []) }

        let candidates = try await callLLM(excerpts: excerpts)

        let filtered = candidates.filter { c in
            let fl = c.find.lowercased()
            let rl = c.replace.lowercased()
            guard !c.find.isEmpty, !c.replace.isEmpty, c.find != c.replace else { return false }
            guard !existingFinds.contains(fl) else { return false }
            guard !rejectedPairs.contains(where: { $0.0 == fl && $0.1 == rl }) else { return false }
            return true
        }

        let high = filtered.filter { $0.confidence == .high }
        let low  = filtered.filter { $0.confidence == .low }
        return (high: high, low: low)
    }

    // MARK: - History loading

    private static func loadHistory() -> [(raw: String, cleaned: String)] {
        guard let data = FileManager.default.contents(atPath: historyPath) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([HistoryEntry].self, from: data) else { return [] }

        return entries.prefix(500).compactMap { entry in
            guard let raw = entry.rawText, !raw.isEmpty, entry.cleanedText != raw else { return nil }
            return (raw: raw, cleaned: entry.cleanedText)
        }
    }

    // MARK: - Existing rules + rejected

    private static func loadExistingFinds() -> Set<String> {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["replacements"] as? [[String: String]] else {
            return []
        }
        return Set(arr.compactMap { $0["find"]?.lowercased() })
    }

    private static func loadRejectedPairs() -> [(String, String)] {
        guard let data = FileManager.default.contents(atPath: rejectedPath),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return []
        }
        return arr.compactMap { dict in
            guard let f = dict["find"]?.lowercased(), let r = dict["replace"]?.lowercased() else { return nil }
            return (f, r)
        }
    }

    // MARK: - Local pre-filter

    private static func buildDiffs(from entries: [(raw: String, cleaned: String)]) -> [(raw: String, cleaned: String, suspectWords: [String])] {
        var rawFreq: [String: Int] = [:]
        var cleanedFreq: [String: Int] = [:]

        for entry in entries {
            tokenize(entry.raw).forEach  { rawFreq[$0, default: 0] += 1 }
            tokenize(entry.cleaned).forEach { cleanedFreq[$0, default: 0] += 1 }
        }

        let suspects: Set<String> = Set(rawFreq.compactMap { (word, count) -> String? in
            guard count >= 3, !stopwords.contains(word) else { return nil }
            let cleanCount = cleanedFreq[word] ?? 0
            let ratio = cleanCount == 0 ? 0.0 : Double(cleanCount) / Double(count)
            return ratio < 0.10 ? word : nil
        })

        guard !suspects.isEmpty else { return [] }

        return entries.compactMap { entry in
            let rawWords = Set(tokenize(entry.raw))
            let hits = rawWords.intersection(suspects)
            guard !hits.isEmpty else { return nil }
            return (raw: entry.raw, cleaned: entry.cleaned, suspectWords: Array(hits))
        }
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    // MARK: - Excerpt selection

    private static func selectExcerpts(
        from diffs: [(raw: String, cleaned: String, suspectWords: [String])],
        existingFinds: Set<String>,
        rejectedPairs: [(String, String)]
    ) -> [(raw: String, cleaned: String)] {
        let filtered = diffs.filter { entry in
            entry.suspectWords.contains { !existingFinds.contains($0) }
        }

        var total = 0
        var result: [(raw: String, cleaned: String)] = []
        for entry in filtered.prefix(30) {
            let rawSnippet = String(entry.raw.prefix(300))
            let cleanedSnippet = String(entry.cleaned.prefix(300))
            let added = rawSnippet.count + cleanedSnippet.count + 10
            guard total + added < 15_000 else { break }
            result.append((raw: rawSnippet, cleaned: cleanedSnippet))
            total += added
        }
        return result
    }

    // MARK: - LLM call

    private static func callLLM(excerpts: [(raw: String, cleaned: String)]) async throws -> [ReplacementCandidate] {
        guard let url = URL(string: "\(Config.openAIBaseURL)/chat/completions") else {
            throw SuggesterError.invalidURL
        }

        let pairsText = excerpts.enumerated().map { (i, pair) in
            "[\(i + 1)] RAW: \(pair.raw)\n    CLEANED: \(pair.cleaned)"
        }.joined(separator: "\n\n")

        let userMessage = """
        Below are raw transcription / cleaned-text pairs from a speech-to-text app. \
        Identify systematic transcription errors — words or short phrases that appear in raw \
        but are consistently corrected in cleaned.

        \(pairsText)

        Return ONLY a JSON array. Each item: {"find": str, "replace": str, "occurrences": int, "confidence": "high"|"low", "evidence": str}
        confidence is "high" if the same substitution appears 3+ times and is clearly a transcription error; "low" otherwise.
        No prose, no markdown fences.
        """

        let payload: [String: Any] = [
            "model": Config.gptModel,
            "temperature": 0.1,
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": "You are a transcription-error analyst. Output only valid JSON arrays."],
                ["role": "user", "content": userMessage]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "Unknown error"
            throw SuggesterError.apiError(errorBody)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SuggesterError.parseError
        }

        let extracted = extractJSONArray(from: content)
        guard let jsonData = extracted.data(using: .utf8),
              let rawItems = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
            let preview = String(content.prefix(300)).replacingOccurrences(of: "\n", with: " ⏎ ")
            throw SuggesterError.apiError("LLM returned non-JSON content: \(preview)")
        }

        return rawItems.compactMap { item in
            guard let find = item["find"] as? String,
                  let replace = item["replace"] as? String,
                  let confidenceStr = item["confidence"] as? String else { return nil }
            let occurrences = (item["occurrences"] as? Int)
                ?? Int(item["occurrences"] as? String ?? "") ?? 1
            let evidence = (item["evidence"] as? String) ?? ""
            let confidence: ReplacementCandidate.Confidence = confidenceStr.lowercased() == "high" ? .high : .low
            return ReplacementCandidate(find: find, replace: replace, occurrences: occurrences, confidence: confidence, evidence: evidence)
        }
    }

    private static func extractJSONArray(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let endRange = s.range(of: "```", options: .backwards) {
                s = String(s[..<endRange.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let first = s.firstIndex(of: "["), let last = s.lastIndex(of: "]"), first <= last {
            s = String(s[first...last])
        }
        return s
    }
}

import Foundation

enum TranscriptionMode: String {
    case local   // whisper.cpp server on localhost
    case cloud   // OpenAI Whisper API
}

enum CleanupMode: String {
    case off     // No AI cleanup — raw transcription only
    case local   // Local LLM via Ollama
    case cloud   // OpenAI GPT API
}

enum Config {
    static let whisperModel = "whisper-1"
    static let gptModel = "gpt-4o-mini"
    static let openAIBaseURL = "https://api.openai.com/v1"

    // MARK: - Local Server Defaults

    /// whisper.cpp server (launched via `whisper-server`)
    static let localWhisperURL = "http://127.0.0.1:8080"

    /// Ollama API (default install)
    static let localOllamaURL = "http://127.0.0.1:11434"
    static let localOllamaModel = "llama3.2:3b"

    // MARK: - Mode Selection (read from env file)

    static var transcriptionMode: TranscriptionMode {
        if let raw = readEnvValue("TRANSCRIPTION_MODE"),
           let mode = TranscriptionMode(rawValue: raw.lowercased()) {
            return mode
        }
        // Default: local if no API key, cloud if API key exists
        return hasAPIKey ? .cloud : .local
    }

    static var cleanupMode: CleanupMode {
        if let raw = readEnvValue("CLEANUP_MODE"),
           let mode = CleanupMode(rawValue: raw.lowercased()) {
            return mode
        }
        // Default: off in local mode, cloud in cloud mode
        return transcriptionMode == .local ? .off : .cloud
    }

    static var localWhisperBaseURL: String {
        return readEnvValue("LOCAL_WHISPER_URL") ?? localWhisperURL
    }

    static var localOllamaBaseURL: String {
        return readEnvValue("LOCAL_OLLAMA_URL") ?? localOllamaURL
    }

    static var localLLMModel: String {
        return readEnvValue("LOCAL_LLM_MODEL") ?? localOllamaModel
    }

    // MARK: - API Key (only needed for cloud mode)

    static var apiKey: String {
        if let key = readKeyFromEnvFile() {
            return key
        }
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            return key
        }
        // In local mode, no key is needed
        if transcriptionMode == .local && cleanupMode != .cloud {
            return ""
        }
        fatalError("No OpenAI API key found. Create ~/.custom-wispr.env with OPENAI_API_KEY=your-key-here, set OPENAI_API_KEY env var, or switch to local mode.")
    }

    static var hasAPIKey: Bool {
        if readKeyFromEnvFile() != nil { return true }
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty { return true }
        return false
    }

    /// In local mode, the app works without any API key
    static var isConfigured: Bool {
        if transcriptionMode == .local && cleanupMode != .cloud {
            return true
        }
        return hasAPIKey
    }

    static func saveAPIKey(_ key: String) -> Bool {
        var envValues = readAllEnvValues()
        envValues["OPENAI_API_KEY"] = key
        return writeEnvFile(envValues)
    }

    static func saveMode(transcription: TranscriptionMode, cleanup: CleanupMode) -> Bool {
        var envValues = readAllEnvValues()
        envValues["TRANSCRIPTION_MODE"] = transcription.rawValue
        envValues["CLEANUP_MODE"] = cleanup.rawValue
        return writeEnvFile(envValues)
    }

    // MARK: - Env File Helpers

    private static func readKeyFromEnvFile() -> String? {
        return readEnvValue("OPENAI_API_KEY")
    }

    private static func readEnvValue(_ key: String) -> String? {
        let path = NSString("~/.custom-wispr.env").expandingTildeInPath
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        let prefix = "\(key)="
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                let value = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func readAllEnvValues() -> [String: String] {
        let path = NSString("~/.custom-wispr.env").expandingTildeInPath
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }

        var result: [String: String] = [:]
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if let eqIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[trimmed.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eqIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !key.isEmpty {
                    result[key] = value
                }
            }
        }
        return result
    }

    private static func writeEnvFile(_ values: [String: String]) -> Bool {
        let path = NSString("~/.custom-wispr.env").expandingTildeInPath
        let fm = FileManager.default

        if fm.fileExists(atPath: path),
           let attrs = try? fm.attributesOfItem(atPath: path),
           let posix = attrs[.posixPermissions] as? Int {
            if posix & 0o077 != 0 {
                fputs("[WARNING] ~/.custom-wispr.env is readable by other users. Run: chmod 600 ~/.custom-wispr.env\n", stderr)
            }
        }

        var lines: [String] = []
        let sortedKeys = values.keys.sorted { a, b in
            if a == "OPENAI_API_KEY" { return true }
            if b == "OPENAI_API_KEY" { return false }
            return a < b
        }
        for key in sortedKeys {
            if let val = values[key], !val.isEmpty {
                lines.append("\(key)=\(val)")
            }
        }

        let content = lines.joined(separator: "\n") + "\n"
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            fputs("[ERROR] Failed to save env file: \(error.localizedDescription)\n", stderr)
            return false
        }
    }
}

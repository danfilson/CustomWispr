import Foundation

class WhisperService {

    /// URLSession with a hard cap on total request time (upload + server processing + download)
    /// The local whisper.cpp server sends no bytes until transcription completes, so the
    /// idle timeout must cover the full processing time of a long recording — 30s here
    /// caused URLSession to disconnect mid-transcription and the server to abort the job.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120  // max idle time between packets
        config.timeoutIntervalForResource = 150 // max total time for entire request
        return URLSession(configuration: config)
    }()

    /// `prompt` biases the model with preceding context — used when transcribing
    /// streamed chunks so each chunk continues naturally from the previous one.
    func transcribe(audioFileURL: URL, prompt: String? = nil) async throws -> String {
        // Retry once on transient failure
        do {
            return try await attemptTranscribe(audioFileURL: audioFileURL, prompt: prompt)
        } catch {
            if isTransient(error) {
                log("Whisper request failed (\(error.localizedDescription)), retrying once...")
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s backoff
                return try await attemptTranscribe(audioFileURL: audioFileURL, prompt: prompt)
            }
            throw error
        }
    }

    private func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotConnectToHost, .cannotFindHost].contains(urlError.code)
        }
        if let whisperError = error as? WhisperError,
           case .apiError(let code, _) = whisperError, code >= 500 {
            return true // server errors are retryable
        }
        return false
    }

    private func attemptTranscribe(audioFileURL: URL, prompt: String?) async throws -> String {
        switch Config.transcriptionMode {
        case .local:
            return try await transcribeLocal(audioFileURL: audioFileURL, prompt: prompt)
        case .cloud:
            return try await transcribeCloud(audioFileURL: audioFileURL, prompt: prompt)
        }
    }

    // MARK: - Warm-up

    private let warmUpLock = NSLock()
    private var warmUpRunning = false
    private var lastWarmUpDone: Date?
    private var lastWarmUpFailureLog: Date?
    private var lastWarmUpNote = "none"

    /// Outcome of the most recent key-down warm-up, for the history record.
    func warmUpNote() -> String {
        warmUpLock.lock(); defer { warmUpLock.unlock() }
        return lastWarmUpNote
    }

    /// Fire-and-forget request with a short speech clip so the OS pages the mmap'd model
    /// back into RAM. The clip must contain speech: the server's VAD skips silence.
    func warmUp() async {
        guard let clip = Bundle.main.url(forResource: "warmup", withExtension: "wav") else { return }
        warmUpLock.lock()
        if warmUpRunning || (lastWarmUpDone.map { Date().timeIntervalSince($0) < 120 } ?? false) {
            lastWarmUpNote = warmUpRunning ? "skipped (running)" : "skipped (recent)"
            warmUpLock.unlock()
            return
        }
        warmUpRunning = true
        warmUpLock.unlock()

        log("Whisper warm-up sent")
        let started = Date()
        var failure: Error?
        do {
            _ = try await transcribeLocal(audioFileURL: clip, timeout: 30)
        } catch {
            failure = error
        }

        warmUpLock.lock()
        warmUpRunning = false
        if let failure {
            let shouldLog = lastWarmUpFailureLog.map { Date().timeIntervalSince($0) >= 300 } ?? true
            if shouldLog { lastWarmUpFailureLog = Date() }
            lastWarmUpNote = "failed"
            warmUpLock.unlock()
            if shouldLog { log("Whisper warm-up failed: \(failure.localizedDescription)") }
        } else {
            lastWarmUpDone = Date()
            lastWarmUpNote = String(format: "done %.1fs", Date().timeIntervalSince(started))
            warmUpLock.unlock()
            log(String(format: "Whisper warm-up done in %.1fs", Date().timeIntervalSince(started)))
        }
    }

    // MARK: - Local whisper.cpp Server

    /// Sends audio to a local whisper.cpp server running the OpenAI-compatible API.
    /// Start the server with: whisper-server -m /path/to/model.bin --host 127.0.0.1 --port 8080
    private func transcribeLocal(audioFileURL: URL, prompt: String? = nil, timeout: TimeInterval? = nil) async throws -> String {
        let baseURL = Config.localWhisperBaseURL
        guard let url = URL(string: "\(baseURL)/inference") else {
            throw WhisperError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let timeout { request.timeoutInterval = timeout }

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioFileURL)
        var body = Data()

        // temperature field (lower = more deterministic)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n".data(using: .utf8)!)
        body.append("0.0\r\n".data(using: .utf8)!)

        // prompt field — preceding-chunk context for streamed transcription
        if let prompt = prompt, !prompt.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(prompt)\r\n".data(using: .utf8)!)
        }

        // response_format field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)

        // audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "Unknown error"
            throw WhisperError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // whisper.cpp server returns {"text": "..."} by default
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let text = json?["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback: decode as standard Whisper response
        let result = try JSONDecoder().decode(WhisperResponse.self, from: data)
        return result.text
    }

    // MARK: - Cloud (OpenAI Whisper API)

    private func transcribeCloud(audioFileURL: URL, prompt: String? = nil) async throws -> String {
        guard let url = URL(string: "\(Config.openAIBaseURL)/audio/transcriptions") else {
            throw WhisperError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioFileURL)
        var body = Data()

        // model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(Config.whisperModel)\r\n".data(using: .utf8)!)

        // language hint — skips auto-detection for faster processing
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("en\r\n".data(using: .utf8)!)

        // prompt field — preceding-chunk context for streamed transcription
        if let prompt = prompt, !prompt.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(prompt)\r\n".data(using: .utf8)!)
        }

        // audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "Unknown error"
            throw WhisperError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let result = try JSONDecoder().decode(WhisperResponse.self, from: data)
        return result.text
    }

    // MARK: - Health Check

    /// Check if the local whisper.cpp server is reachable
    static func isLocalServerRunning() async -> Bool {
        let baseURL = Config.localWhisperBaseURL
        guard let url = URL(string: baseURL) else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.httpMethod = "GET"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return http.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Types

    struct WhisperResponse: Decodable {
        let text: String
    }

    enum WhisperError: LocalizedError {
        case invalidURL
        case invalidResponse
        case apiError(statusCode: Int, message: String)
        case serverNotRunning

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid Whisper API URL"
            case .invalidResponse:
                return "Invalid response from Whisper API"
            case .apiError(let code, let message):
                return "Whisper API error (\(code)): \(message)"
            case .serverNotRunning:
                return "Local whisper.cpp server is not running. Start it with: whisper-server -m /path/to/model.bin"
            }
        }
    }
}

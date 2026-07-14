import Cocoa
import AVFoundation

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    fputs("[\(timestamp)] CustomWispr: \(message)\n", stderr)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayWindow()
    private let recorder = AudioRecorder()
    private let whisper = WhisperService()
    private let cleanup = AICleanupService()
    private let injector = TextInjector()
    private let keyMonitor = KeyMonitor()

    private let settingsWindow = SettingsWindow()
    private let welcomeWindow = WelcomeWindow()

    private var listenMenuItem: NSMenuItem!
    private var isRecording = false
    private var isProcessing = false
    private var processingTask: Task<Void, Never>?
    private var maxRecordingTimer: Timer?
    private let maxRecordingDuration: TimeInterval = 300 // 5 minutes
    private let maxProcessingDuration: UInt64 = 150_000_000_000 // 150 seconds in nanoseconds

    // Streaming transcription: chunks arrive (possibly out of order, all on main)
    // as the recorder rotates files mid-dictation; each is transcribed immediately
    // in a serial chain so only the short final chunk remains after key-up.
    private var pendingChunks: [Int: URL] = [:]
    private var nextChunkIndex = 0
    private var expectedTotalChunks: Int?
    private var chunkChain: [Task<String, Error>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Kill any existing instance so new builds always take over cleanly
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != myPID }
        for app in others {
            log("Terminating existing instance (PID \(app.processIdentifier))")
            app.terminate()
        }
        if !others.isEmpty { Thread.sleep(forTimeInterval: 0.5) }

        log("App launched")
        AudioRecorder.cleanupStaleFiles()

        // Always set up menu bar so icon is visible
        setupMenuBar()

        let hasOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

        if !hasOnboarded {
            log("First launch, showing welcome window")
            welcomeWindow.onComplete = { [weak self] in
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                self?.finishStartup()
            }
            welcomeWindow.show()
        } else if !Config.isConfigured {
            log("Not configured, showing welcome window")
            welcomeWindow.onComplete = { [weak self] in
                self?.finishStartup()
            }
            welcomeWindow.show()
        } else {
            finishStartup()
        }
    }

    private func finishStartup() {
        requestPermissions()
        startKeyMonitor()

        // Flip the overlay to "Listening..." only when audio is actually flowing —
        // the honest cue for when it's safe to start talking.
        recorder.onFirstBuffer = { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.overlay.show(status: "Listening...")
        }
        recorder.onChunkReady = { [weak self] url, index in
            self?.chunkArrived(url: url, index: index)
        }
        recorder.prewarm()

        // No automatic update check: this fork lags upstream version numbers by
        // design, so the modal was a permanent nag. The monthly health-check
        // routine reviews upstream releases and assesses them instead.
    }

    // MARK: - Menu Bar

    private func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let w = rect.width
            let h = rect.height

            // Microphone head — circle centered in upper portion
            let circleRadius: CGFloat = 5.5
            let circleCenter = NSPoint(x: w / 2, y: h - 1 - circleRadius)
            let circlePath = NSBezierPath(
                ovalIn: NSRect(
                    x: circleCenter.x - circleRadius,
                    y: circleCenter.y - circleRadius,
                    width: circleRadius * 2,
                    height: circleRadius * 2
                )
            )
            circlePath.lineWidth = 1.6
            NSColor.black.setStroke()
            circlePath.stroke()

            // Stem — short line down from circle
            let stemTop = circleCenter.y - circleRadius
            let stemBottom = stemTop - 3.0
            let stemPath = NSBezierPath()
            stemPath.move(to: NSPoint(x: w / 2, y: stemTop))
            stemPath.line(to: NSPoint(x: w / 2, y: stemBottom))
            stemPath.lineWidth = 1.6
            stemPath.lineCapStyle = .round
            stemPath.stroke()

            // Base — horizontal line at bottom
            let baseY = stemBottom
            let baseHalf: CGFloat = 3.5
            let basePath = NSBezierPath()
            basePath.move(to: NSPoint(x: w / 2 - baseHalf, y: baseY))
            basePath.line(to: NSPoint(x: w / 2 + baseHalf, y: baseY))
            basePath.lineWidth = 1.6
            basePath.lineCapStyle = .round
            basePath.stroke()

            return true
        }
        return image
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let icon = makeMenuBarIcon()
            icon.isTemplate = true
            button.image = icon
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "CustomWispr", action: nil, keyEquivalent: ""))

        listenMenuItem = NSMenuItem(title: "Start Listening", action: #selector(toggleListening), keyEquivalent: "")
        listenMenuItem.target = self
        menu.addItem(listenMenuItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        log("Menu bar setup complete")
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func toggleListening() {
        if isRecording {
            keyMonitor.isRecordingToggle = false
            handleFnUp()
        } else if !isProcessing {
            keyMonitor.isRecordingToggle = true
            handleFnDown()
        }
    }

    private func updateListenMenuItem() {
        listenMenuItem?.title = isRecording ? "Stop Listening" : "Start Listening"
    }

    @objc private func quit() {
        keyMonitor.stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Permissions

    private func requestPermissions() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        log("Microphone status: \(micStatus.rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")

        if micStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                log("Microphone permission \(granted ? "granted" : "denied")")
            }
        } else if micStatus == .denied {
            log("WARNING: Microphone denied. Please enable in System Settings > Privacy & Security > Microphone")
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log("Accessibility trusted: \(trusted)")
    }

    // MARK: - Key Monitor

    private func startKeyMonitor() {
        keyMonitor.onFnKeyDown = { [weak self] in
            log("F5 pressed — starting recording")
            self?.handleFnDown()
        }
        keyMonitor.onFnKeyUp = { [weak self] in
            log("F5 pressed — stopping recording")
            self?.handleFnUp()
        }

        if keyMonitor.start() {
            log("Key monitor started successfully")
        } else {
            log("ERROR: Failed to start key monitor. Check Accessibility permissions.")
        }
    }

    // MARK: - Recording Flow

    private func handleFnDown() {
        guard Config.isConfigured else {
            log("Ignoring F5 down (not configured)")
            return
        }

        // If processing is stuck, cancel it so user can start fresh
        if isProcessing {
            log("Cancelling stuck processing task")
            processingTask?.cancel()
            processingTask = nil
            chunkChain.forEach { $0.cancel() }
            isProcessing = false
            overlay.hide()
            recorder.cleanup()
        }

        guard !isRecording else {
            log("Ignoring F5 down (already recording)")
            return
        }
        isRecording = true
        updateListenMenuItem()

        // Reset streaming-transcription state for this dictation
        pendingChunks = [:]
        nextChunkIndex = 0
        expectedTotalChunks = nil
        chunkChain = []

        // onFirstBuffer upgrades this to "Listening..." once audio is flowing
        overlay.show(status: "Starting...")

        do {
            _ = try recorder.startRecording()
            log("Recording started")

            maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingDuration, repeats: false) { [weak self] _ in
                log("Max recording duration reached (5 min), auto-stopping")
                self?.handleFnUp()
            }
        } catch {
            log("ERROR: Failed to start recording: \(error.localizedDescription)")
            isRecording = false
            updateListenMenuItem()
            overlay.hide()
        }
    }

    private func handleFnUp() {
        guard isRecording else { return }
        isRecording = false
        isProcessing = true
        updateListenMenuItem()
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil

        let result = recorder.stopRecording()

        guard result.totalChunks > 0, result.totalFrames > 0 else {
            log("No audio captured, nothing to transcribe")
            isProcessing = false
            overlay.hide()
            recorder.cleanup()
            updateListenMenuItem()
            return
        }

        overlay.show(status: "Transcribing...")
        log("Recording stopped, finishing \(result.totalChunks) chunk(s) (mode: \(Config.transcriptionMode))...")

        if let url = result.finalChunk {
            chunkArrived(url: url, index: result.finalChunkIndex)
        }
        expectedTotalChunks = result.totalChunks
        maybeFinishDictation()
    }

    // MARK: - Streaming Transcription

    /// Chunks arrive on the main queue but rotation callbacks are dispatched async,
    /// so the final chunk can land before a just-rotated one — buffer by index and
    /// enqueue strictly in order.
    private func chunkArrived(url: URL, index: Int) {
        pendingChunks[index] = url
        while let next = pendingChunks[nextChunkIndex] {
            pendingChunks.removeValue(forKey: nextChunkIndex)
            enqueueChunk(url: next, index: nextChunkIndex)
            nextChunkIndex += 1
        }
        maybeFinishDictation()
    }

    /// Each chunk transcribes in a serial chain: it awaits the accumulated text of
    /// all previous chunks and passes its tail as the whisper prompt, so chunk
    /// boundaries keep vocabulary and sentence flow. Mid-dictation chunks start
    /// transcribing while the user is still talking.
    private func enqueueChunk(url: URL, index: Int) {
        let previous = chunkChain.last
        let whisper = self.whisper
        let task = Task<String, Error> {
            let prior = try await previous?.value ?? ""
            try Task.checkCancellation()
            let prompt = prior.isEmpty ? nil : String(prior.suffix(400))
            let text = try await whisper.transcribe(audioFileURL: url, prompt: prompt)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            log("Chunk \(index) transcribed (\(trimmed.count) chars)")
            if trimmed.isEmpty { return prior }
            return prior.isEmpty ? trimmed : AppDelegate.joinDedupingOverlap(prior, trimmed)
        }
        chunkChain.append(task)
    }

    /// A chunk cut can land inside a word, making whisper emit it at both the end
    /// of one chunk and the start of the next ("...to the client. client. Marker...").
    /// Drop the longest run of words duplicated across the seam before joining.
    static func joinDedupingOverlap(_ prior: String, _ next: String, maxOverlapWords: Int = 6) -> String {
        func key(_ word: Substring) -> String {
            word.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let priorWords = prior.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let nextWords = next.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let limit = min(maxOverlapWords, priorWords.count, nextWords.count)
        for n in stride(from: limit, through: 1, by: -1) {
            let tail = priorWords.suffix(n).map(key)
            let head = nextWords.prefix(n).map(key)
            if tail == head, !tail.contains("") {
                let remainder = nextWords.dropFirst(n).joined(separator: " ")
                return remainder.isEmpty ? prior : prior + " " + remainder
            }
        }
        return prior + " " + next
    }

    /// Runs once recording has stopped AND every chunk has been enqueued: awaits
    /// the tail of the chain (usually just the short final chunk at this point),
    /// then cleans up and injects.
    private func maybeFinishDictation() {
        guard isProcessing, processingTask == nil,
              let total = expectedTotalChunks, nextChunkIndex >= total else { return }
        expectedTotalChunks = nil

        let chain = chunkChain.last
        let allChunkTasks = chunkChain

        processingTask = Task {
            // On failure, keep the recording so the dictation isn't lost — it's the only
            // copy of what was said. Stale files are swept at next app launch.
            var keepAudioAfterFailure = false
            defer {
                DispatchQueue.main.async { [weak self] in
                    self?.isProcessing = false
                    self?.processingTask = nil
                    self?.overlay.hide()
                    if keepAudioAfterFailure {
                        log("Processing failed — chunk audio kept in temp dir for recovery (custom-wispr_*)")
                    } else {
                        self?.recorder.cleanup()
                    }
                    self?.updateListenMenuItem()
                }
            }

            do {
                // Overall timeout: race the pipeline against a deadline
                try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { [self] in
                        let rawText = try await chain?.value ?? ""

                        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            log("Empty transcription, skipping")
                            return ""
                        }

                        // Clean up with AI
                        await MainActor.run { overlay.show(status: "Cleaning up...") }
                        let cleanedText = await cleanup.cleanup(rawText: rawText)

                        // Save to history (before paste, so it's retrievable even if paste fails)
                        HistoryManager.shared.addEntry(cleanedText: cleanedText, rawText: rawText)

                        return cleanedText
                    }

                    // Timeout task
                    group.addTask { [self] in
                        try await Task.sleep(nanoseconds: maxProcessingDuration)
                        throw ProcessingError.timeout
                    }

                    // Take whichever finishes first
                    if let result = try await group.next() {
                        group.cancelAll()
                        if !result.isEmpty {
                            await MainActor.run { [self] in
                                // Copy to clipboard so Cmd+V works as fallback
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(result, forType: .string)
                                injector.inject(text: result)
                                log("Text injected and copied to clipboard")
                            }
                        }
                    }
                }
            } catch is CancellationError {
                log("Processing was cancelled by user")
                allChunkTasks.forEach { $0.cancel() }
            } catch ProcessingError.timeout {
                keepAudioAfterFailure = true
                allChunkTasks.forEach { $0.cancel() }
                log("ERROR: Processing timed out after \(maxProcessingDuration / 1_000_000_000)s")
            } catch {
                keepAudioAfterFailure = true
                log("ERROR: Processing failed: \(error.localizedDescription)")
            }
        }
    }

    private enum ProcessingError: Error {
        case timeout
    }
}

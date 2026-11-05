import Cocoa
import AVFoundation

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] CustomWispr: \(message)\n"
    fputs(line, stderr)
    LogFile.shared.append(line)
}

/// Persistent copy of the log at ~/Library/Logs/CustomWispr.log. A login-launched
/// menu-bar app has no stderr, so without this every per-stage timestamp the app
/// emits is lost and a hung dictation can't be diagnosed after the fact. Rotates
/// once at 5 MB, keeping a single CustomWispr.1.log.
final class LogFile {
    static let shared = LogFile()
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CustomWispr.log")
    private let maxBytes: UInt64 = 5_000_000
    private let lock = NSLock()
    private var handle: FileHandle?

    func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        if handle == nil { open() }
        guard let handle else { return }
        handle.write(data)
        if ((try? handle.offset()) ?? 0) > maxBytes { rotate() }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let previous = url.deletingLastPathComponent().appendingPathComponent("CustomWispr.1.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        open()
    }
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
    private var styleMenuItems: [String: NSMenuItem] = [:]
    /// Resolved at F5 key-down from the frontmost app, so it reflects where the user was
    /// when they started speaking, not where they are when processing finishes.
    private var dictationStyle: CleanupStyle = .verbatim
    private var isRecording = false
    private var isProcessing = false
    private var processingTask: Task<Void, Never>?
    private var processingStartedAt: Date?
    /// An F5 press during processing only cancels it once it has run this long. Before
    /// 2026-10-16 any press cancelled: a 5-minute dictation auto-stopped at the cap, the
    /// user pressed F5 a second later to stop it, and the whole dictation was discarded.
    /// Past the 150s processing timeout plus slack, the job really is stuck.
    private let stuckProcessingThreshold: TimeInterval = 180
    private var cleanupWarningToken: UUID?
    private let cleanupWarningDuration: TimeInterval = 3
    private var maxRecordingTimer: Timer?
    private let maxRecordingDuration: TimeInterval = 300 // 5 minutes
    private let maxProcessingDuration: UInt64 = 150_000_000_000 // 150 seconds in nanoseconds

    // Recording tail (ported from upstream v1.6.0). F5 is often pressed while the
    // last word is still being spoken, so every stop keeps the mic open this long
    // before the real stop runs. isRecording stays true for the whole tail: the
    // recorder is still capturing, chunk rotation still fires, and the overlay and
    // menu still show recording. isStopping marks that a finish is pending; an F5
    // press during the tail cancels it and the same recording simply continues.
    private var isStopping = false
    private var pendingFinish: DispatchWorkItem?
    private let recordingTailDuration: TimeInterval = 0.5

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
            self.audioArrived = true
            self.overlay.show(status: "Listening...")
        }
        recorder.onAudioStalled = { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.overlay.show(status: "Mic stopped — press F5 to stop")
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

        let styleItem = NSMenuItem(title: "Cleanup style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for (title, key) in [("Auto", "auto"), ("Verbatim", "verbatim"), ("Tidy", "tidy")] {
            let item = NSMenuItem(title: title, action: #selector(selectCleanupStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = SettingsManager.shared.cleanupStyleOverride == key ? .on : .off
            styleMenu.addItem(item)
            styleMenuItems[key] = item
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

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

    @objc private func selectCleanupStyle(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        SettingsManager.shared.cleanupStyleOverride = key
        for (k, item) in styleMenuItems { item.state = k == key ? .on : .off }
        log("Cleanup style override: \(key)")
    }

    /// Frontmost app and its focused window title (title is "" if Accessibility can't read it).
    private func resolveDictationStyle() {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleId = app?.bundleIdentifier ?? ""
        var title = ""
        if let pid = app?.processIdentifier {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.25)  // never let a hung app delay key-down
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value) == .success {
                    title = value as? String ?? ""
                }
            }
        }
        dictationStyle = SettingsManager.shared.resolveStyle(bundleId: bundleId, windowTitle: title)
        log("Cleanup style: \(dictationStyle.rawValue) (\(bundleId.isEmpty ? "unknown app" : bundleId))")
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

    /// Set by onFirstBuffer; lets the start watchdog tell a dead mic from a live one.
    private var audioArrived = false

    private func handleFnDown() {
        guard Config.isConfigured else {
            log("Ignoring F5 down (not configured)")
            return
        }

        // A press during processing is usually a late "stop" (e.g. right after the
        // max-duration auto-stop). Ignore it unless processing is genuinely stuck.
        if isProcessing {
            let elapsed = processingStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            guard elapsed >= stuckProcessingThreshold else {
                log(String(format: "Ignoring F5 down (still processing, %.0fs in)", elapsed))
                keyMonitor.isRecordingToggle = false
                return
            }
            // Stuck: start fresh, but keep the audio — it's the only copy of the
            // dictation. Stale files are swept at next app launch.
            log("Cancelling stuck processing task — chunk audio kept in temp dir for recovery (custom-wispr_*)")
            processingTask?.cancel()
            processingTask = nil
            chunkChain.forEach { $0.cancel() }
            isProcessing = false
            processingStartedAt = nil
            overlay.hide()
            recorder.abandonChunks()
        }

        // Pressed again during the tail: the user isn't done. Drop the pending finish
        // and keep the same recording (and its chunks) going.
        if isStopping {
            pendingFinish?.cancel()
            pendingFinish = nil
            isStopping = false
            keyMonitor.isRecordingToggle = true
            if maxRecordingTimer == nil { armMaxRecordingTimer() }
            log("Tail cancelled by key-down, continuing recording")
            return
        }

        guard !isRecording else {
            log("Ignoring F5 down (already recording)")
            return
        }
        resolveDictationStyle()
        isRecording = true
        updateListenMenuItem()

        // Reset streaming-transcription state for this dictation
        pendingChunks = [:]
        nextChunkIndex = 0
        expectedTotalChunks = nil
        chunkChain = []

        // onFirstBuffer upgrades this to "Listening..." once audio is flowing
        overlay.show(status: "Starting...")
        audioArrived = false

        do {
            _ = try recorder.startRecording()
            log("Recording started")

            // Page the model back in while the user is still speaking (local mode only).
            if Config.transcriptionMode == .local {
                let whisper = self.whisper
                Task { await whisper.warmUp() }
            }

            // Don't leave "Starting..." up forever if the mic never delivers audio.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.isRecording, !self.isStopping, !self.audioArrived else { return }
                log("WARNING: No audio from the mic 2s after start")
                self.overlay.show(status: "No audio from mic")
            }

            armMaxRecordingTimer()
        } catch {
            log("ERROR: Failed to start recording: \(error.localizedDescription)")
            isRecording = false
            updateListenMenuItem()
            overlay.hide()
        }
    }

    private func armMaxRecordingTimer() {
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingDuration, repeats: false) { [weak self] _ in
            log("Max recording duration reached (5 min), auto-stopping")
            guard let self else { return }
            self.maxRecordingTimer = nil
            // Sync the toggle so the next F5 press reads as "start" (which, inside
            // the tail, cancels it) rather than a no-op "stop".
            self.keyMonitor.isRecordingToggle = false
            self.handleFnUp()
        }
    }

    /// Every stop (F5, menu toggle, max-duration timer) lands here. The mic stays
    /// open for recordingTailDuration, then finishRecordingAndProcess() runs the
    /// real stop. The tail only lengthens the final chunk; AudioRecorder's
    /// final-chunk gate still discards it if it holds no voiced audio.
    private func handleFnUp() {
        guard isRecording, !isStopping else { return }
        isStopping = true
        log(String(format: "Key released, holding mic %.1fs", recordingTailDuration))

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isStopping else { return }
            self.pendingFinish = nil
            self.finishRecordingAndProcess()
        }
        pendingFinish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + recordingTailDuration, execute: work)
    }

    private func finishRecordingAndProcess() {
        guard isRecording else { return }
        isStopping = false
        isRecording = false
        isProcessing = true
        processingStartedAt = Date()
        updateListenMenuItem()
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil
        log("Tail elapsed, stopping recorder")

        let result = recorder.stopRecording()

        guard result.totalChunks > 0, result.totalFrames > 0 else {
            log("No audio captured, nothing to transcribe")
            isProcessing = false
            processingStartedAt = nil
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
            let glossary = SettingsManager.shared.whisperGlossary()
            if index == 0, glossary.terms > 0 {
                log("Whisper glossary: \(glossary.terms) terms (\(glossary.text.count) chars)")
            }
            let tail = prior.isEmpty ? "" : String(prior.suffix(400))
            let combined = [glossary.text, tail].filter { !$0.isEmpty }.joined(separator: " ")
            let prompt = combined.isEmpty ? nil : combined
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
        let style = dictationStyle

        processingTask = Task {
            // On failure, keep the recording so the dictation isn't lost — it's the only
            // copy of what was said. Stale files are swept at next app launch.
            var keepAudioAfterFailure = false
            // Set when cleanup fell back to raw text; the overlay reports it instead of
            // hiding, so a broken cleanup path can't stay invisible the way a dead API
            // key once did for weeks.
            var cleanupWarning: String?
            defer {
                let warning = cleanupWarning
                DispatchQueue.main.async { [weak self] in
                    self?.isProcessing = false
                    self?.processingTask = nil
                    self?.processingStartedAt = nil
                    if let warning {
                        self?.showCleanupWarning(warning)
                    } else {
                        self?.overlay.hide()
                    }
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
                try await withThrowingTaskGroup(of: AICleanupService.CleanupResult.self) { group in
                    group.addTask { [self] in
                        let rawText = try await chain?.value ?? ""

                        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            log("Empty transcription, skipping")
                            return AICleanupService.CleanupResult(text: "", fallbackReason: nil)
                        }

                        // Clean up with AI
                        await MainActor.run { overlay.show(status: "Cleaning up...") }
                        let result = await cleanup.cleanup(rawText: rawText, style: style)

                        // Save to history (before paste, so it's retrievable even if paste fails)
                        HistoryManager.shared.addEntry(cleanedText: result.text, rawText: rawText, style: style.rawValue)

                        return result
                    }

                    // Timeout task
                    group.addTask { [self] in
                        try await Task.sleep(nanoseconds: maxProcessingDuration)
                        throw ProcessingError.timeout
                    }

                    // Take whichever finishes first
                    if let result = try await group.next() {
                        group.cancelAll()
                        cleanupWarning = result.fallbackReason
                        if !result.text.isEmpty {
                            await MainActor.run { [self] in
                                // Copy to clipboard so Cmd+V works as fallback
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(result.text, forType: .string)
                                injector.inject(text: result.text)
                                log("Text injected and copied to clipboard")
                            }
                        }
                    }
                }
            } catch is CancellationError {
                // handleFnDown has already handed the chunk files off; deleting them
                // here would also hit the next recording's chunks.
                keepAudioAfterFailure = true
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

    /// Reports why the pasted text is raw, then clears itself. The text has already been
    /// injected by this point, so this is a notice and never blocks. A dictation started
    /// before the timer fires owns the overlay — the token stops a stale timer from
    /// hiding the new "Listening..." out from under it.
    private func showCleanupWarning(_ reason: String) {
        let token = UUID()
        cleanupWarningToken = token
        overlay.show(status: "⚠ \(reason)")
        log("Cleanup fell back to raw text: \(reason)")

        DispatchQueue.main.asyncAfter(deadline: .now() + cleanupWarningDuration) { [weak self] in
            guard let self, self.cleanupWarningToken == token,
                  !self.isRecording, !self.isProcessing else { return }
            self.overlay.hide()
        }
    }

    private enum ProcessingError: Error {
        case timeout
    }
}

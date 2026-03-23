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

    private var isRecording = false
    private var isProcessing = false
    private var maxRecordingTimer: Timer?
    private let maxRecordingDuration: TimeInterval = 300 // 5 minutes

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Check for updates after a short delay so the app feels snappy
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            UpdateChecker.checkForUpdates()
        }
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
        guard !isRecording && !isProcessing else {
            log("Ignoring F5 down (recording=\(isRecording), processing=\(isProcessing))")
            return
        }
        isRecording = true

        do {
            _ = try recorder.startRecording()
            overlay.show(status: "Listening...")
            log("Recording started")

            maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingDuration, repeats: false) { [weak self] _ in
                log("Max recording duration reached (5 min), auto-stopping")
                self?.handleFnUp()
            }
        } catch {
            log("ERROR: Failed to start recording: \(error.localizedDescription)")
            isRecording = false
        }
    }

    private func handleFnUp() {
        guard isRecording else { return }
        isRecording = false
        isProcessing = true
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil

        guard let audioURL = recorder.stopRecording() else {
            log("ERROR: No audio file after stopping recording")
            isProcessing = false
            overlay.hide()
            return
        }

        let fileExists = FileManager.default.fileExists(atPath: audioURL.path)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        log("Audio file: \(audioURL.path), exists: \(fileExists), size: \(fileSize) bytes")

        overlay.show(status: "Processing...")
        log("Recording stopped, processing...")

        Task {
            defer {
                DispatchQueue.main.async { [weak self] in
                    self?.isProcessing = false
                    self?.overlay.hide()
                    self?.recorder.cleanup()
                }
            }

            do {
                // Step 1: Transcribe
                log("Starting transcription (mode: \(Config.transcriptionMode))...")
                let rawText = try await whisper.transcribe(audioFileURL: audioURL)
                #if DEBUG
                log("Transcribed: \(rawText.prefix(100))...")
                #endif

                guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    log("Empty transcription, skipping")
                    return
                }

                // Step 2: Clean up with AI
                let cleanedText = await cleanup.cleanup(rawText: rawText)
                #if DEBUG
                log("Cleaned: \(cleanedText.prefix(100))...")
                #endif

                // Save to history (before paste, so it's retrievable even if paste fails)
                HistoryManager.shared.addEntry(cleanedText: cleanedText, rawText: rawText)

                // Step 3: Inject into active text field
                DispatchQueue.main.async { [weak self] in
                    self?.injector.inject(text: cleanedText)
                    log("Text injected successfully")
                }
            } catch {
                log("ERROR: Processing failed: \(error.localizedDescription)")
            }
        }
    }
}

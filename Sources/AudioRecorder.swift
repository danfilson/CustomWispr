import AVFoundation
import CoreAudio
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    /// Used instead of the engine when the selected mic isn't the system default.
    private var directCapture: DirectCapture?
    private var isCapturing: Bool { audioEngine != nil || directCapture != nil }
    private var prewarmedEngine: AVAudioEngine?
    private var stallTimer: Timer?
    private var stallRebuilds = 0
    /// Called on main when the mic can't be revived mid-recording.
    var onAudioStalled: (() -> Void)?
    private var configChangeObserver: NSObjectProtocol?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var fileProcessingFormat: AVAudioFormat?
    private var tapFormat: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var firstBufferReported = false

    // Streaming chunks: the recording is cut into pieces at silence points so each
    // piece can be transcribed while the user is still talking.
    private var fileSettings: [String: Any] = [:]
    private var chunkExtension = "wav"
    private var chunkIndex = 0
    private var chunkFramesWritten: AVAudioFramePosition = 0
    private var currentChunkURL: URL?
    private var chunkURLs: [URL] = []

    /// Prefer cutting at a pause after this many seconds of chunk audio...
    private let minChunkSeconds: Double = 15
    /// ...but never let a chunk exceed this, even mid-word.
    private let maxChunkSeconds: Double = 30
    /// A final chunk shorter than this is discarded as key-noise, not speech.
    private let minFinalChunkSeconds: Double = 0.3

    // Silence gate. Whisper large-v3 hallucinates on audio with no speech in it —
    // a near-silent clip reliably comes back as "Thank you." with no_speech_prob ≈ 0,
    // so the server can't be asked to filter it. The common case is the tail chunk:
    // the user finishes a sentence, the pause rotates the chunk, and the key is
    // released a second later, leaving 0.3–2s of room tone that transcribes as
    // "Thank you." stitched onto the end. A chunk is sent only if it held at least
    // this many voiced buffers (~85ms each at 48kHz/4096 frames).
    private var chunkVoicedBuffers = 0
    private let minVoicedBuffersForSpeech = 3   // ≈0.26s of voice
    /// Speech level of the previous dictation. 5% of it is an extra floor for
    /// "voiced", so a recording with no speech at all (where the running level
    /// never learns anything) is still gated — while a mic 10× quieter than the
    /// last one still clears it, so a mic change can never silently eat speech.
    private var lastSpeechLevel: Float = 0

    // Cutting on a single quiet buffer (~85ms) splits phrases at inter-word gaps
    // and whisper then drops the orphaned fragment. A cut requires a sustained
    // pause — several consecutive buffers below a threshold that adapts to the
    // speaker's actual level (mic gain and distance vary wildly).
    private var quietBufferRun = 0
    private var runningSpeechLevel: Float = 0
    private let quietBuffersForCut = 3          // ≈0.26s at 48kHz/4096-frame buffers
    private let absoluteSilenceFloor: Float = 0.0025

    // The tap fires on the audio render thread while start/stop run on main;
    // this lock guards the file/converter handoff between the two.
    private let fileLock = NSLock()

    /// Called on the main queue when the first buffer of a recording lands in the
    /// file — the honest "you can talk now" signal for the overlay.
    var onFirstBuffer: (() -> Void)?

    /// Called on the main queue each time a mid-recording chunk is finalized and
    /// ready to transcribe. The final chunk is returned by stopRecording() instead.
    var onChunkReady: ((URL, Int) -> Void)?

    private var deviceToRestore: AudioDeviceID?

    // MARK: - Pre-warm

    /// Build and prepare an engine ahead of time so startRecording() only has to call
    /// engine.start() — cold construction costs 100ms+ and clips the first word.
    /// Only possible when no input-device switch is needed, because AVAudioEngine
    /// binds to the system default input device at creation time.
    func prewarm() {
        guard prewarmedEngine == nil, !isCapturing else { return }
        if let preferred = AudioRecorder.preferredInputDeviceID(),
           let current = AudioRecorder.defaultInputDeviceID(),
           preferred != current {
            log("Pre-warm skipped: selected mic differs from system default (will capture from it directly)")
            return
        }
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log("Pre-warm skipped: no usable input format")
            return
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }
        engine.prepare()
        prewarmedEngine = engine
        tapFormat = format
        observeConfigChanges(for: engine)
        log("Audio engine pre-warmed (\(Int(format.sampleRate))Hz, \(format.channelCount)ch)")
    }

    /// Rebuild the pre-warmed engine when the audio route changes underneath it
    /// (mic unplugged, AirPods connected, sleep/wake) — a stale engine either
    /// fails to start or records from the wrong device.
    private func observeConfigChanges(for engine: AVAudioEngine) {
        removeConfigObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.isCapturing else { return }
            log("Audio configuration changed — rebuilding pre-warmed engine")
            self.discardPrewarmedEngine()
            self.prewarm()
        }
    }

    private func removeConfigObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    private func discardPrewarmedEngine() {
        if let engine = prewarmedEngine {
            engine.inputNode.removeTap(onBus: 0)
        }
        prewarmedEngine = nil
        tapFormat = nil
        removeConfigObserver()
    }

    // MARK: - Recording

    func startRecording() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let useWAV = Config.transcriptionMode == .local
        let ext = useWAV ? "wav" : "m4a"
        let fileURL = tempDir.appendingPathComponent("custom-wispr_\(UUID().uuidString).\(ext)")

        // Fast path: pre-warmed engine, still valid for the current mic selection
        if let engine = prewarmedEngine, let format = tapFormat {
            let micUnchanged: Bool = {
                guard let preferred = AudioRecorder.preferredInputDeviceID(),
                      let current = AudioRecorder.defaultInputDeviceID() else { return true }
                return preferred == current
            }()
            if micUnchanged {
                do {
                    try beginRecording(engine: engine, recordingFormat: format,
                                       fileURL: fileURL, useWAV: useWAV, prewarmed: true)
                    startStallMonitor(useWAV: useWAV)
                    return fileURL
                } catch {
                    log("Pre-warmed start failed (\(error.localizedDescription)); falling back to cold start")
                    discardPrewarmedEngine()
                }
            } else {
                log("Selected mic changed; discarding pre-warmed engine")
                discardPrewarmedEngine()
            }
        }

        // Selected mic isn't the default (e.g. AirPods connected, webcam selected):
        // capture straight from that device. No system-default switching, which
        // is what kept breaking — see DirectCapture.
        deviceToRestore = nil
        if let preferred = AudioRecorder.preferredInputDeviceID(),
           preferred != AudioRecorder.defaultInputDeviceID(),
           let uid = AudioRecorder.deviceUID(preferred),
           let capture = DirectCapture(deviceUID: uid, onBuffer: { [weak self] in self?.handleTap(buffer: $0) }) {
            log("Recording on input device \(preferred) (\(AudioRecorder.deviceName(preferred) ?? "unknown")) directly; system default untouched")
            try beginRecording(engine: nil, recordingFormat: capture.format,
                               fileURL: fileURL, useWAV: useWAV, prewarmed: false,
                               start: { try capture.start() })
            directCapture = capture
            startStallMonitor(useWAV: useWAV)
            return fileURL
        }

        // Cold path: switch device if needed, then build the engine fresh
        let (engine, recordingFormat) = try buildColdEngine()
        try beginRecording(engine: engine, recordingFormat: recordingFormat,
                           fileURL: fileURL, useWAV: useWAV, prewarmed: false)
        startStallMonitor(useWAV: useWAV)
        return fileURL
    }

    /// Switches the system default input to the selected mic (restored in
    /// stopRecording) and builds an engine on it. AVAudioEngine can't simply be
    /// bound to a non-default input on macOS while output is on another device —
    /// tested 2026-11-02 with AirPods as output: the tap delivers zero frames.
    ///
    /// The switch is asynchronous inside CoreAudio. An engine built while it is still
    /// settling (typical right after AirPods connect) binds to the previous device's
    /// format — seen as 24kHz or 44.1kHz/2ch instead of the webcam's 48kHz/1ch — and
    /// captures nothing, leaving the overlay on "Starting..." for the whole press.
    /// So: rebuild until the engine's format matches the selected mic's own rate.
    private func buildColdEngine() throws -> (AVAudioEngine, AVAudioFormat) {
        var target: AudioDeviceID?
        if let deviceID = AudioRecorder.preferredInputDeviceID() {
            target = deviceID
            let current = AudioRecorder.defaultInputDeviceID()
            if current == deviceID {
                log("Recording on input device \(deviceID) (\(AudioRecorder.deviceName(deviceID) ?? "unknown")); already the default")
            } else if AudioRecorder.setDefaultInputDevice(deviceID) {
                if deviceToRestore == nil { deviceToRestore = current }
                log("Recording on input device \(deviceID) (\(AudioRecorder.deviceName(deviceID) ?? "unknown")); will restore default afterward")
            } else {
                target = nil
                log("WARNING: Could not switch to selected mic; using system default input")
            }
        } else {
            log("WARNING: No usable input device found; using system default input")
        }

        let expectedRate = target.flatMap { AudioRecorder.nominalSampleRate($0) }
        var engine = AVAudioEngine()
        var format = engine.inputNode.outputFormat(forBus: 0)
        if let expected = expectedRate, let target = target {
            var attempt = 0
            while (abs(format.sampleRate - expected) > 1 || AudioRecorder.defaultInputDeviceID() != target),
                  attempt < 8 {
                attempt += 1
                Thread.sleep(forTimeInterval: 0.1)
                engine = AVAudioEngine()
                format = engine.inputNode.outputFormat(forBus: 0)
            }
            if attempt > 0 {
                log(String(format: "Input switch settled after %d rebuild(s): %.0fHz %dch (mic reports %.0fHz)",
                           attempt, format.sampleRate, format.channelCount, expected))
            }
        }

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noMicrophone
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }
        engine.prepare()
        return (engine, format)
    }

    /// Safety net for the same race, and for a mic that drops out mid-dictation:
    /// if no new audio has reached the file for 1s while recording, swap in a fresh
    /// engine and keep writing to the same chunk. On 2026-11-02 a 3.5-minute
    /// dictation was lost because the engine delivered 0.2s of audio and then went
    /// silent, and nothing noticed — the old one-shot start check only caught zero.
    private func startStallMonitor(useWAV: Bool) {
        stallTimer?.invalidate()
        stallRebuilds = 0
        var lastFrames: AVAudioFramePosition = -1
        var lastProgress = Date()
        stallTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self, self.isCapturing else { timer.invalidate(); return }
            self.fileLock.lock()
            let frames = self.framesWritten + AVAudioFramePosition(self.chunkIndex) // rotation counts as progress
            self.fileLock.unlock()
            if frames != lastFrames {
                lastFrames = frames
                lastProgress = Date()
                return
            }
            guard Date().timeIntervalSince(lastProgress) >= 1.0 else { return }
            guard self.stallRebuilds < 3 else {
                timer.invalidate()
                log("ERROR: Mic still delivering no audio after 3 engine rebuilds — giving up")
                self.onAudioStalled?()
                return
            }
            self.stallRebuilds += 1
            lastProgress = Date()
            log("WARNING: No new audio for 1s (\(frames) frames so far) — rebuilding engine, attempt \(self.stallRebuilds)")
            self.swapEngine(useWAV: useWAV)
        }
    }

    /// Replace the running engine without touching the chunk files, so audio
    /// already captured is kept and new audio continues in the current chunk.
    private func swapEngine(useWAV: Bool) {
        if let capture = directCapture {
            capture.restart()
            log("Direct capture restarted")
            return
        }
        if let old = audioEngine {
            old.inputNode.removeTap(onBus: 0)
            old.stop()
        }
        audioEngine = nil
        do {
            let (engine, format) = try buildColdEngine()
            fileLock.lock()
            if let fileFormat = fileProcessingFormat {
                let differs = format.sampleRate != fileFormat.sampleRate
                    || format.channelCount != fileFormat.channelCount
                if useWAV {
                    converter = differs ? AVAudioConverter(from: format, to: fileFormat) : nil
                } else if let old = tapFormat, old.sampleRate != format.sampleRate
                            || old.channelCount != format.channelCount {
                    log("WARNING: Mic format changed mid-recording (cloud mode); audio may not be written")
                }
            }
            fileLock.unlock()
            try engine.start()
            audioEngine = engine
            tapFormat = format
            log("Engine rebuilt (\(Int(format.sampleRate))Hz, \(format.channelCount)ch)")
        } catch {
            log("ERROR: Engine rebuild failed: \(error.localizedDescription)")
        }
    }

    private func beginRecording(engine: AVAudioEngine?, recordingFormat: AVAudioFormat,
                                fileURL: URL, useWAV: Bool, prewarmed: Bool,
                                start: (() throws -> Void)? = nil) throws {
        let fileSettings: [String: Any] = useWAV
            ? [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false
            ]
            : [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: recordingFormat.sampleRate,
                AVNumberOfChannelsKey: min(recordingFormat.channelCount, 2),
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                AVEncoderBitRateKey: 32000
            ]

        let file = try AVAudioFile(forWriting: fileURL, settings: fileSettings)

        // AVAudioFile.processingFormat = Float32 non-interleaved at the file's sample rate.
        // Buffers written to the file MUST match this format.
        let fileFormat = file.processingFormat

        var conv: AVAudioConverter?
        if useWAV && recordingFormat.sampleRate != fileFormat.sampleRate {
            conv = AVAudioConverter(from: recordingFormat, to: fileFormat)
            log("Audio converter: \(recordingFormat.sampleRate)Hz \(recordingFormat.channelCount)ch → \(fileFormat.sampleRate)Hz \(fileFormat.channelCount)ch (Float32)")
        }

        fileLock.lock()
        self.audioFile = file
        self.converter = conv
        self.fileProcessingFormat = fileFormat
        self.fileSettings = fileSettings
        self.chunkExtension = fileURL.pathExtension
        self.framesWritten = 0
        self.firstBufferReported = false
        self.chunkIndex = 0
        self.chunkFramesWritten = 0
        self.currentChunkURL = fileURL
        self.chunkURLs = [fileURL]
        self.quietBufferRun = 0
        self.runningSpeechLevel = 0
        self.chunkVoicedBuffers = 0
        fileLock.unlock()

        do {
            if let engine = engine { try engine.start() } else { try start?() }
        } catch {
            fileLock.lock()
            self.audioFile = nil
            self.converter = nil
            self.fileProcessingFormat = nil
            self.currentChunkURL = nil
            fileLock.unlock()
            throw error
        }

        self.audioEngine = engine
        if prewarmed {
            // Promote: the engine keeps its tap; just stop tracking it as pre-warmed
            prewarmedEngine = nil
            removeConfigObserver()
            log("Recording started (pre-warmed engine)")
        }
        self.tapFormat = recordingFormat
    }

    private func handleTap(buffer: AVAudioPCMBuffer) {
        var reportFirstBuffer = false
        var finishedChunk: (URL, Int)?
        let level = AudioRecorder.meanLevel(of: buffer)

        fileLock.lock()
        if let file = audioFile {
            writeBuffer(buffer, to: file)
            if !firstBufferReported {
                firstBufferReported = true
                reportFirstBuffer = true
            }

            // Track the speaker's typical level (EMA over voiced buffers) and count
            // consecutive buffers quiet relative to it.
            if level > absoluteSilenceFloor {
                runningSpeechLevel = runningSpeechLevel == 0
                    ? level
                    : 0.95 * runningSpeechLevel + 0.05 * level
            }
            let silenceThreshold = max(absoluteSilenceFloor, runningSpeechLevel * 0.15)
            quietBufferRun = level < silenceThreshold ? quietBufferRun + 1 : 0
            if level >= max(silenceThreshold, lastSpeechLevel * 0.05) {
                chunkVoicedBuffers += 1
            }

            if let rate = fileProcessingFormat?.sampleRate, rate > 0 {
                let minFrames = AVAudioFramePosition(minChunkSeconds * rate)
                let maxFrames = AVAudioFramePosition(maxChunkSeconds * rate)
                if chunkFramesWritten >= maxFrames
                    || (chunkFramesWritten >= minFrames && quietBufferRun >= quietBuffersForCut) {
                    finishedChunk = rotateChunkLocked()
                    quietBufferRun = 0
                }
            }
        }
        fileLock.unlock()

        if reportFirstBuffer {
            DispatchQueue.main.async { [weak self] in self?.onFirstBuffer?() }
        }
        if let (url, index) = finishedChunk {
            DispatchQueue.main.async { [weak self] in self?.onChunkReady?(url, index) }
        }
    }

    /// Mean absolute sample level of the buffer — cheap voice-activity proxy for
    /// picking chunk cut points at pauses instead of mid-word.
    private static func meanLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            sum += abs(channel[i])
        }
        return sum / Float(buffer.frameLength)
    }

    /// Close the current chunk file and start the next one. Must be called with
    /// fileLock held. Returns the finished chunk for transcription dispatch.
    private func rotateChunkLocked() -> (URL, Int)? {
        guard let finishedURL = currentChunkURL else { return nil }
        let finishedIndex = chunkIndex
        let finishedIsSilent = chunkVoicedBuffers < minVoicedBuffersForSpeech
        let finishedSeconds = Double(chunkFramesWritten) / (fileProcessingFormat?.sampleRate ?? 16000)
        chunkVoicedBuffers = 0

        audioFile = nil // release closes and flushes the file

        let nextURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-wispr_\(UUID().uuidString).\(chunkExtension)")
        do {
            audioFile = try AVAudioFile(forWriting: nextURL, settings: fileSettings)
        } catch {
            // Recording continues without a file only in name; buffers are dropped
            // until stop. Rare — surface loudly in the log.
            log("ERROR: Failed to open next chunk file: \(error.localizedDescription)")
            currentChunkURL = nil
            chunkIndex += 1
            return (finishedURL, finishedIndex)
        }
        chunkFramesWritten = 0
        currentChunkURL = nextURL
        chunkURLs.append(nextURL)
        if finishedIsSilent {
            // Nothing to transcribe; reuse the index so the chain stays contiguous.
            try? FileManager.default.removeItem(at: finishedURL)
            chunkURLs.removeAll { $0 == finishedURL }
            log(String(format: "Chunk %d discarded as silence (%.1fs, no voiced audio)", finishedIndex, finishedSeconds))
            return nil
        }
        chunkIndex += 1
        return (finishedURL, finishedIndex)
    }

    /// Must be called with fileLock held.
    private func writeBuffer(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) {
        // A source can change format under us (device rebuilt, direct capture's
        // first real buffer) — keep the converter matched to what actually arrives.
        if let fileFormat = fileProcessingFormat, fileFormat.commonFormat == .pcmFormatFloat32,
           buffer.format.sampleRate != fileFormat.sampleRate || buffer.format.channelCount != fileFormat.channelCount,
           converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: fileFormat)
        }
        do {
            if let converter = converter, let fileFormat = fileProcessingFormat {
                let ratio = fileFormat.sampleRate / buffer.format.sampleRate
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
                guard let converted = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else { return }
                var error: NSError?
                var consumed = false
                let status = converter.convert(to: converted, error: &error) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                if status == .error {
                    log("ERROR: Audio conversion failed: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                try file.write(from: converted)
                framesWritten += AVAudioFramePosition(converted.frameLength)
                chunkFramesWritten += AVAudioFramePosition(converted.frameLength)
            } else {
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
                chunkFramesWritten += AVAudioFramePosition(buffer.frameLength)
            }
        } catch {
            log("ERROR: Failed to write audio buffer: \(error.localizedDescription)")
        }
    }

    struct StopResult {
        let finalChunk: URL?
        let finalChunkIndex: Int
        let totalChunks: Int
        let totalFrames: AVAudioFramePosition
    }

    func stopRecording() -> StopResult {
        stallTimer?.invalidate()
        stallTimer = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        directCapture?.stop()
        directCapture = nil
        tapFormat = nil

        fileLock.lock()
        let rate = fileProcessingFormat?.sampleRate ?? 16000
        audioFile = nil // release closes and flushes the final chunk
        converter = nil
        fileProcessingFormat = nil
        let frames = framesWritten
        let finalFrames = chunkFramesWritten
        let finalVoiced = chunkVoicedBuffers
        let finalIndex = chunkIndex
        var finalURL = currentChunkURL
        currentChunkURL = nil
        chunkVoicedBuffers = 0
        if runningSpeechLevel > 0 { lastSpeechLevel = runningSpeechLevel }
        var total = finalURL == nil ? chunkIndex : chunkIndex + 1
        // A final chunk with almost no audio is key-release noise, and one with no
        // voiced audio is room tone whisper would hallucinate over — neither is speech.
        if let url = finalURL {
            let tooShort = finalFrames < AVAudioFramePosition(minFinalChunkSeconds * rate)
            let silent = finalVoiced < minVoicedBuffersForSpeech
            if tooShort || silent {
                try? FileManager.default.removeItem(at: url)
                chunkURLs.removeAll { $0 == url }
                finalURL = nil
                total -= 1
                log(String(format: "Final chunk discarded (%.1fs, %d voiced buffers): %@",
                           Double(finalFrames) / rate, finalVoiced, tooShort ? "key noise" : "silence"))
            }
        }
        fileLock.unlock()

        if let restore = deviceToRestore {
            _ = AudioRecorder.setDefaultInputDevice(restore)
            log("Restored system default input device to \(restore)")
            deviceToRestore = nil
        }

        log("Recording stopped: \(frames) frames captured across \(total) chunk(s)")
        if frames == 0 {
            log("WARNING: No audio frames were captured — check the default input device.")
        }

        // Warm up for the next dictation once this key-up handler returns
        DispatchQueue.main.async { [weak self] in self?.prewarm() }

        return StopResult(finalChunk: finalURL, finalChunkIndex: finalIndex,
                          totalChunks: total, totalFrames: frames)
    }

    func cleanup() {
        fileLock.lock()
        let urls = chunkURLs
        chunkURLs = []
        fileLock.unlock()
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Forgets the current chunk files without deleting them, so a cancelled dictation's
    /// audio survives for recovery. cleanupStaleFiles() sweeps them at next launch.
    func abandonChunks() {
        fileLock.lock()
        chunkURLs = []
        fileLock.unlock()
    }

    static func cleanupStaleFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.lastPathComponent.hasPrefix("custom-wispr_") && (file.pathExtension == "wav" || file.pathExtension == "m4a") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Device selection

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev
        ) == noErr, dev != 0 else { return nil }
        return dev
    }

    @discardableResult
    static func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr,
              rate > 0 else { return nil }
        return rate
    }

    static func setDefaultInputDevice(_ device: AudioDeviceID) -> Bool {
        var dev = device
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &dev
        ) == noErr
    }

    static func builtInInputDeviceID() -> AudioDeviceID? {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return nil }

        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &dataSize, &devices
        ) == noErr else { return nil }

        for device in devices where deviceHasInput(device) {
            var transport: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr,
               transport == kAudioDeviceTransportTypeBuiltIn {
                return device
            }
        }
        return nil
    }

    private static func deviceHasInput(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let bufList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufList.deallocate() }

        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, bufList) == noErr else {
            return false
        }

        let abl = UnsafeMutableAudioBufferListPointer(
            bufList.assumingMemoryBound(to: AudioBufferList.self)
        )
        for buffer in abl where buffer.mNumberChannels > 0 {
            return true
        }
        return false
    }

    struct InputDevice {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    static func availableInputDevices() -> [InputDevice] {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &dataSize, &devices
        ) == noErr else { return [] }

        return devices.compactMap { device -> InputDevice? in
            guard deviceHasInput(device),
                  let uid = deviceUID(device),
                  let name = deviceName(device) else { return nil }
            return InputDevice(id: device, uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        availableInputDevices().first { $0.uid == uid }?.id
    }

    static func preferredInputDeviceID() -> AudioDeviceID? {
        let uid = SettingsManager.shared.selectedMicUID
        if !uid.isEmpty, let id = deviceID(forUID: uid) {
            return id
        }
        return builtInInputDeviceID()
    }

    static func deviceUID(_ device: AudioDeviceID) -> String? {
        cfStringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ device: AudioDeviceID) -> String? {
        cfStringProperty(device, kAudioObjectPropertyName)
    }

    private static func cfStringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let str = value else { return nil }
        return str as String
    }

    enum RecorderError: LocalizedError {
        case noMicrophone

        var errorDescription: String? {
            switch self {
            case .noMicrophone:
                return "No microphone available or sample rate is 0."
            }
        }
    }
}


/// Records straight from one input device via AVCaptureSession, independent of
/// the system default input and of the output device.
///
/// Why: with AirPods connected the default input is the AirPods, and the old
/// approach — switch the system default to the selected mic, build an
/// AVAudioEngine, switch back afterwards — kept breaking: engines built mid-switch
/// captured nothing, and on 2026-11-02 engines delivered 0.2s of audio and then
/// stalled (AirPods renegotiating the route kills an engine whose output is on
/// them). Two long dictations were lost. Binding AVAudioEngine's input to a
/// non-default device doesn't work either while output is elsewhere (zero frames).
/// AVCaptureSession is input-only, so none of that applies.
final class DirectCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let format: AVAudioFormat
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "custom-wispr.direct-capture", qos: .userInitiated)
    private let onBuffer: (AVAudioPCMBuffer) -> Void

    init?(deviceUID: String, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        guard let device = AVCaptureDevice(uniqueID: deviceUID),
              let input = try? AVCaptureDeviceInput(device: device),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription),
              asbd.pointee.mSampleRate > 0, asbd.pointee.mChannelsPerFrame > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: asbd.pointee.mSampleRate,
                                         channels: asbd.pointee.mChannelsPerFrame,
                                         interleaved: false)
        else { return nil }
        self.format = format
        self.onBuffer = onBuffer
        super.init()

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { return nil }
        session.addInput(input)
        session.addOutput(output)
    }

    func start() throws {
        session.startRunning()
        guard session.isRunning else { throw AudioRecorder.RecorderError.noMicrophone }
    }

    func stop() {
        session.stopRunning()
        // Drain any buffer already in flight so nothing lands after stop returns.
        queue.sync {}
    }

    func restart() {
        session.stopRunning()
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let fmt = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        ) == noErr else { return }
        onBuffer(buffer)
    }
}

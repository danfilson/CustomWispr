import AVFoundation
import CoreAudio
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var prewarmedEngine: AVAudioEngine?
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
        guard prewarmedEngine == nil, audioEngine == nil else { return }
        if let preferred = AudioRecorder.preferredInputDeviceID(),
           let current = AudioRecorder.defaultInputDeviceID(),
           preferred != current {
            log("Pre-warm skipped: selected mic differs from system default (will switch at record time)")
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
            guard let self = self, self.audioEngine == nil else { return }
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

        // Cold path: switch device if needed, then build the engine fresh
        deviceToRestore = nil
        if let deviceID = AudioRecorder.preferredInputDeviceID() {
            let current = AudioRecorder.defaultInputDeviceID()
            if current != deviceID {
                if AudioRecorder.setDefaultInputDevice(deviceID) {
                    deviceToRestore = current
                    log("Recording on input device \(deviceID) (\(AudioRecorder.deviceName(deviceID) ?? "unknown")); will restore default afterward")
                } else {
                    log("WARNING: Could not switch to selected mic; using system default input")
                }
            } else {
                log("Recording on input device \(deviceID) (\(AudioRecorder.deviceName(deviceID) ?? "unknown")); already the default")
            }
        } else {
            log("WARNING: No usable input device found; using system default input")
        }

        let engine = AVAudioEngine()
        let recordingFormat = engine.inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw RecorderError.noMicrophone
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }
        engine.prepare()

        try beginRecording(engine: engine, recordingFormat: recordingFormat,
                           fileURL: fileURL, useWAV: useWAV, prewarmed: false)
        return fileURL
    }

    private func beginRecording(engine: AVAudioEngine, recordingFormat: AVAudioFormat,
                                fileURL: URL, useWAV: Bool, prewarmed: Bool) throws {
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
        fileLock.unlock()

        do {
            try engine.start()
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
        chunkIndex += 1
        chunkFramesWritten = 0
        currentChunkURL = nextURL
        chunkURLs.append(nextURL)
        return (finishedURL, finishedIndex)
    }

    /// Must be called with fileLock held.
    private func writeBuffer(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) {
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
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        tapFormat = nil

        fileLock.lock()
        let rate = fileProcessingFormat?.sampleRate ?? 16000
        audioFile = nil // release closes and flushes the final chunk
        converter = nil
        fileProcessingFormat = nil
        let frames = framesWritten
        let finalFrames = chunkFramesWritten
        let finalIndex = chunkIndex
        var finalURL = currentChunkURL
        currentChunkURL = nil
        var total = finalURL == nil ? chunkIndex : chunkIndex + 1
        // A final chunk with almost no audio is key-release noise, not speech
        if let url = finalURL, finalFrames < AVAudioFramePosition(minFinalChunkSeconds * rate) {
            try? FileManager.default.removeItem(at: url)
            chunkURLs.removeAll { $0 == url }
            finalURL = nil
            total -= 1
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

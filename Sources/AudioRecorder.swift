import AVFoundation
import CoreAudio
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var framesWritten: AVAudioFramePosition = 0

    private var deviceToRestore: AudioDeviceID?

    func startRecording() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("custom-wispr_\(UUID().uuidString).m4a")
        self.tempFileURL = fileURL
        self.framesWritten = 0

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
        let inputNode = engine.inputNode

        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw RecorderError.noMicrophone
        }

        let audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: recordingFormat.sampleRate,
                AVNumberOfChannelsKey: min(recordingFormat.channelCount, 2),
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                AVEncoderBitRateKey: 32000
            ]
        )

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            do {
                try audioFile.write(from: buffer)
                self?.framesWritten += AVAudioFramePosition(buffer.frameLength)
            } catch {
                log("ERROR: Failed to write audio buffer: \(error.localizedDescription)")
            }
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.audioFile = audioFile

        return fileURL
    }

    func stopRecording() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil

        if let restore = deviceToRestore {
            _ = AudioRecorder.setDefaultInputDevice(restore)
            log("Restored system default input device to \(restore)")
            deviceToRestore = nil
        }

        log("Recording stopped: \(framesWritten) frames captured")
        if framesWritten == 0 {
            log("WARNING: No audio frames were captured — check the default input device.")
        }

        return tempFileURL
    }

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
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

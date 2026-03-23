import AVFoundation
import Foundation

class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var tempFileURL: URL?

    func startRecording() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("custom-wispr_\(UUID().uuidString).wav")
        self.tempFileURL = fileURL

        // Record directly at 16kHz mono 16-bit PCM — whisper.cpp compatible
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]

        let audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        guard audioRecorder.record() else {
            throw RecorderError.noMicrophone
        }

        self.recorder = audioRecorder
        return fileURL
    }

    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        return tempFileURL
    }

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }

    /// Remove stale temp files from previous sessions
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

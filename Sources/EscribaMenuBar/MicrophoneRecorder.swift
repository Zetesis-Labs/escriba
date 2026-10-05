import AVFoundation
import EscribaModel

enum MicrophoneError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart: "el micrófono no empezó a grabar"
        }
    }
}

final class MicrophoneRecorder {
    private var recorder: AVAudioRecorder?

    func port() -> AudioRecorder {
        AudioRecorder(
            requestPermission: { await AVCaptureDevice.requestAccess(for: .audio) },
            start: { [self] url in
                let recorder = try AVAudioRecorder(
                    url: url,
                    settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    ])
                recorder.isMeteringEnabled = true
                guard recorder.record() else { throw MicrophoneError.couldNotStart }
                self.recorder = recorder
            },
            stop: { [self] in
                recorder?.stop()
                recorder = nil
            },
            cancel: { [self] in
                recorder?.stop()
                recorder?.deleteRecording()
                recorder = nil
            },
            decibels: { [self] in
                recorder?.updateMeters()
                return recorder?.averagePower(forChannel: 0) ?? -160
            },
            elapsed: { [self] in recorder?.currentTime ?? 0 })
    }
}

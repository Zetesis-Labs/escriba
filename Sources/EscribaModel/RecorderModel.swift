import Foundation
import Observation
import EscribaCore
import EscribaSystemKit

public struct AudioRecorder {
    public var requestPermission: () async -> Bool
    public var start: (URL) throws -> Void
    public var stop: () -> Void
    public var cancel: () -> Void
    public var decibels: () -> Float
    public var elapsed: () -> TimeInterval

    public init(
        requestPermission: @escaping () async -> Bool,
        start: @escaping (URL) throws -> Void,
        stop: @escaping () -> Void,
        cancel: @escaping () -> Void,
        decibels: @escaping () -> Float,
        elapsed: @escaping () -> TimeInterval
    ) {
        self.requestPermission = requestPermission
        self.start = start
        self.stop = stop
        self.cancel = cancel
        self.decibels = decibels
        self.elapsed = elapsed
    }
}

@Observable
public final class RecorderModel {
    public enum State: Equatable {
        case idle
        case asking
        case recording(Date)
        case denied
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var level: Double = 0
    public private(set) var elapsed: TimeInterval = 0

    @ObservationIgnored private let recorder: AudioRecorder
    @ObservationIgnored private let inbox: Inbox
    @ObservationIgnored private let wake: () -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private let ticks: Bool
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init(
        recorder: AudioRecorder, inbox: Inbox, wake: @escaping () -> Void,
        now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current, ticks: Bool = true
    ) {
        self.recorder = recorder
        self.inbox = inbox
        self.wake = wake
        self.now = now
        self.timeZone = timeZone
        self.ticks = ticks
    }

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    public var clock: String { durationClock(elapsed) }

    public var problem: String? {
        switch state {
        case .denied:
            "Escriba no tiene permiso para usar el micrófono. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Micrófono."
        case .failed(let message):
            message
        default:
            nil
        }
    }

    public func start() async {
        guard state == .idle || state == .denied || problem != nil else { return }
        state = .asking
        guard await recorder.requestPermission() else {
            state = .denied
            return
        }
        do {
            let url = try inbox.recordingURL()
            try recorder.start(url)
            file = url
            level = 0
            elapsed = 0
            state = .recording(now())
            startTicking()
        } catch {
            state = .failed("No se pudo empezar a grabar: \(error.localizedDescription)")
        }
    }

    public func stop() {
        guard case .recording(let startedAt) = state, let file else { return }
        recorder.stop()
        finish()
        do {
            try inbox.finishRecording(file, recordingName(startedAt: startedAt, timeZone: timeZone), startedAt)
            state = .idle
            wake()
        } catch {
            state = .failed("No se pudo guardar la grabación: \(error.localizedDescription)")
        }
    }

    public func cancel() {
        guard isRecording, let file else { return }
        recorder.cancel()
        inbox.discardRecording(file)
        finish()
        state = .idle
    }

    public func refresh() {
        guard isRecording else { return }
        level = meterLevel(decibels: recorder.decibels())
        elapsed = recorder.elapsed()
    }

    public func dismissProblem() {
        guard problem != nil else { return }
        state = .idle
    }

    private func startTicking() {
        guard ticks else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func finish() {
        ticker?.cancel()
        ticker = nil
        file = nil
        level = 0
    }
}

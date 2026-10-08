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
    public static let levelHistory = 48

    public private(set) var level: Double = 0
    public private(set) var levels: [Double] = []
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var recipe: String?

    @ObservationIgnored private let recorder: AudioRecorder
    @ObservationIgnored private let inbox: Inbox
    @ObservationIgnored private let wake: () -> Void
    @ObservationIgnored private let keepAwake: () -> () -> Void
    @ObservationIgnored private var release: (() -> Void)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private let ticks: Bool
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init(
        recorder: AudioRecorder, inbox: Inbox, wake: @escaping () -> Void,
        keepAwake: @escaping () -> () -> Void = { {} },
        now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current, ticks: Bool = true
    ) {
        self.recorder = recorder
        self.inbox = inbox
        self.wake = wake
        self.keepAwake = keepAwake
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

    public func start(recipe: String? = nil) async {
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
            self.recipe = recipe
            level = 0
            levels = []
            elapsed = 0
            release = keepAwake()
            state = .recording(now())
            startTicking()
        } catch {
            state = .failed("No se pudo empezar a grabar: \(error.localizedDescription)")
        }
    }

    public func stop() {
        guard case .recording(let startedAt) = state, let file else { return }
        let recipe = recipe
        recorder.stop()
        finish()
        let name = recordingName(startedAt: startedAt, timeZone: timeZone)
        do {
            try inbox.finishRecording(file, name, startedAt, recipe)
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
        levels = Array((levels + [level]).suffix(Self.levelHistory))
        elapsed = recorder.elapsed()
    }

    public func prepareForQuit() {
        stop()
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
        release?()
        release = nil
        ticker?.cancel()
        ticker = nil
        file = nil
        recipe = nil
        level = 0
        levels = []
    }
}

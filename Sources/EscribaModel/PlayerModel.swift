import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
public final class PlayerModel {
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var isPlaying = false

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var observerToken: Any?

    public init() {}

    isolated deinit {
        unload()
    }

    public func load(_ url: URL) {
        unload()
        let created = AVPlayer(url: url)
        player = created
        currentTime = 0
        duration = 0

        let (times, continuation) = AsyncStream.makeStream(of: TimeInterval.self)
        observerToken = created.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { time in
            continuation.yield(time.seconds)
        }
        ticker = Task { [weak self] in
            for await time in times { self?.tick(time) }
        }
        Task { [weak self] in
            let seconds = try? await created.currentItem?.asset.load(.duration).seconds
            self?.duration = seconds ?? 0
        }
    }

    public func toggle() {
        isPlaying ? pause() : play()
    }

    public func play() {
        player?.play()
        isPlaying = true
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    public func seek(to time: TimeInterval, thenPlay: Bool = true) {
        player?.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
        if thenPlay { play() }
    }

    private func tick(_ time: TimeInterval) {
        currentTime = time
        if isPlaying, duration > 0, time >= duration - 0.05 { isPlaying = false }
    }

    private func unload() {
        ticker?.cancel()
        ticker = nil
        if let observerToken, let player { player.removeTimeObserver(observerToken) }
        observerToken = nil
        player?.pause()
        player = nil
    }
}

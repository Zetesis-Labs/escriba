import Foundation
import Observation
import EscribaEngine
import EscribaSystemKit

@Observable
public final class AppLogModel {
    public private(set) var lines: [LogEntry] = []
    public private(set) var problem: String?

    private let url: URL
    private let maxBytes: Int
    private let interval: Duration
    @ObservationIgnored private var polling: Task<Void, Never>?

    public init(url: URL, maxBytes: Int = 256 * 1024, interval: Duration = .seconds(1)) {
        self.url = url
        self.maxBytes = maxBytes
        self.interval = interval
    }

    public func start() {
        polling?.cancel()
        let (url, maxBytes, interval) = (url, maxBytes, interval)
        polling = Task {
            var lastSize: Int?
            while !Task.isCancelled {
                let size = fileSize(of: url)
                if size != lastSize {
                    lastSize = size
                    do {
                        let tail = try await offloaded { try logTail(of: url, maxBytes: maxBytes) }
                        lines = tail.map(parseLogLine)
                        problem = nil
                    } catch {
                        problem = "no se pudo leer el log: \(error)"
                    }
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        polling?.cancel()
        polling = nil
    }
}

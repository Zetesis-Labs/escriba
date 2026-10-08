import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ConnectorHTTP: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var bytes = Data()
        var response: HTTPURLResponse?
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
        var session: URLSession?
        var task: URLSessionDataTask?
        var cancelled = false
    }
    private let state = Mutex(State())
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(request, continuation: continuation)
            }
        } onCancel: { self.cancel() }
    }

    private func start(_ request: URLRequest, continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) {
        state.withLock { state in
            guard !state.cancelled else { continuation.resume(throwing: CancellationError()); return }
            state.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            state.session = session
            let task = session.dataTask(with: request)
            state.task = task
            task.resume()
        }
    }

    private func cancel() {
        let task = state.withLock { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        state.withLock { $0.response = response }
        if response.expectedContentLength > limit {
            finish(.failure(ConnectorHostError.limit))
            completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = state.withLock { state in
            let exceeded = state.bytes.count + data.count > limit
            if !exceeded { state.bytes.append(data) }
            return exceeded
        }
        if exceeded { finish(.failure(ConnectorHostError.limit)); dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (response, bytes, cancelled) = state.withLock { ($0.response, $0.bytes, $0.cancelled) }
        if cancelled { finish(.failure(CancellationError())) }
        else if error != nil { finish(.failure(ConnectorHostError.transport)) }
        else if let response { finish(.success((bytes, response))) }
        else { finish(.failure(ConnectorHostError.transport)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), any Error>) {
        let (continuation, session) = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            let session = state.session
            state.session = nil
            state.task = nil
            return (continuation, session)
        }
        continuation?.resume(with: result)
        session?.invalidateAndCancel()
    }
}

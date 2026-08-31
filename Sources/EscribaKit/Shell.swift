import Foundation

public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
        public let errorOutput: String
    }

    public static func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws
        -> Result
    {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw TranscriptionError.backendUnavailable("no encuentro el ejecutable \(executable)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let readers = DispatchGroup()
        let outData = Box()
        let errData = Box()
        drain(out, into: outData, group: readers)
        drain(err, into: errData, group: readers)

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            kill(process, exited: exited)
            readers.wait()
            throw TranscriptionError.timedOut(timeout)
        }

        readers.wait()

        return Result(
            status: process.terminationStatus,
            output: decode(outData.value),
            errorOutput: decode(errData.value)
        )
    }

    private static func kill(_ process: Process, exited: DispatchSemaphore) {
        process.terminate()
        if exited.wait(timeout: .now() + 5) == .timedOut, process.isRunning {
            Foundation.kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 5)
        }
    }

    private static func decode(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private static func drain(_ pipe: Pipe, into box: Box, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            box.append(pipe.fileHandleForReading.readDataToEndOfFile())
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(data)
        }
    }
}

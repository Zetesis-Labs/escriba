import Darwin
import Foundation
import Synchronization

private final class ProtocolOutput: Sendable {
    nonisolated private let handle: Mutex<FileHandle>

    init(fileDescriptor: Int32) {
        handle = Mutex(FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true))
    }

    nonisolated func send(_ frame: String) {
        do {
            try handle.withLock { output in
                try output.write(contentsOf: Data((frame + "\n").utf8))
            }
        } catch {
            fputs("EscribaNativeHost: protocol output failed\n", stderr)
            exit(1)
        }
    }
}

@main
struct NativeHostMain {
    static func main() async {
        // Preserve the protocol channel, then send all Swift/third-party stdout to stderr.
        let protocolFD = dup(STDOUT_FILENO)
        guard protocolFD >= 0 else { exit(1) }
        let output = ProtocolOutput(fileDescriptor: protocolFD)
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { exit(1) }

        let host = NativeHost()
        while let line = readLine() {
            let response = await host.handle(line, onProgress: { id, fraction in
                if fraction.isFinite, (0...1).contains(fraction) {
                    output.send(NativeHost.progressFrame(id: id, fraction: fraction))
                }
            })
            output.send(response)
        }
    }
}

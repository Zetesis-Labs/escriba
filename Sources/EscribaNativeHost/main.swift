import Darwin
import Foundation

@main
struct NativeHostMain {
    static func main() async {
        // Preserve the protocol channel, then send all Swift/third-party stdout to stderr.
        let protocolFD = dup(STDOUT_FILENO)
        guard protocolFD >= 0 else { exit(1) }
        let output = FileHandle(fileDescriptor: protocolFD, closeOnDealloc: true)
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { exit(1) }

        let host = NativeHost()
        while let line = readLine() {
            let response = await host.handle(line)
            do {
                try output.write(contentsOf: Data((response + "\n").utf8))
            } catch {
                fputs("EscribaNativeHost: protocol output failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }
}

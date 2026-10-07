import CoreFoundation
import Foundation

final class RunLoopExecutor: SerialExecutor {
    // CFRunLoopPerformBlock y CFRunLoopWakeUp se pueden llamar desde cualquier hilo.
    nonisolated(unsafe) private let loop: CFRunLoop

    init(name: String) {
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var started: CFRunLoop?
        let thread = Thread {
            started = CFRunLoopGetCurrent()
            RunLoop.current.add(Timer(timeInterval: .greatestFiniteMagnitude, repeats: false) { _ in }, forMode: .default)
            ready.signal()
            while true {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = name
        thread.start()
        ready.wait()
        loop = started!
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            job.runSynchronously(on: executor)
        }
        CFRunLoopWakeUp(loop)
    }

    func isIsolatingCurrentContext() -> Bool? {
        CFRunLoopGetCurrent() === loop
    }

    func checkIsolated() {
        precondition(CFRunLoopGetCurrent() === loop, "esto tiene que correr en el hilo del compilador de recetas")
    }
}

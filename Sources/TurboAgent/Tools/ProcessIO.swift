import Foundation
import Darwin

/// Bounded, cancellable pipe I/O, used only on dedicated blocking queues.
enum ProcessIO {
    static func check(_ cancellation: AgentCancellation, deadline: ContinuousClock.Instant) throws {
        try cancellation.check()
        if ContinuousClock.now >= deadline { throw ACPError(code: -32000, message: "Process operation timed out") }
    }

    static func nonblocking(_ handle: FileHandle) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    static func write(_ data: Data, to handle: FileHandle, cancellation: AgentCancellation, deadline: ContinuousClock.Instant) throws {
        let fd = handle.fileDescriptor
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try check(cancellation, deadline: deadline)
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                if ready < 0 && errno == EINTR { continue }
                if ready == 0 { continue }
                guard ready > 0 else { throw ACPError.disconnected }
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw ACPError.disconnected }
                offset += count
            }
        }
    }

    static func read(from handle: FileHandle, cancellation: AgentCancellation, deadline: ContinuousClock.Instant) throws -> Data? {
        let fd = handle.fileDescriptor
        while true {
            try check(cancellation, deadline: deadline)
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 && errno == EINTR { continue }
            if ready == 0 { continue }
            guard ready > 0 else { throw ACPError.disconnected }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count >= 0 else { throw ACPError.disconnected }
            return count == 0 ? nil : Data(bytes.prefix(count))
        }
    }

    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        // Foundation creates a process group on macOS. Only target a group
        // when it belongs to this child, never the agent/client's group.
        let target = getpgid(pid) == pid ? -pid : pid
        kill(target, SIGKILL)
        // Foundation's waitUntilExit can stall when launch and cleanup occur
        // on different executor threads. Let Foundation reap asynchronously;
        // never turn cancellation into an unbounded run-loop wait.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while process.isRunning && ContinuousClock.now < deadline {
            if kill(pid, 0) < 0 && errno == ESRCH { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

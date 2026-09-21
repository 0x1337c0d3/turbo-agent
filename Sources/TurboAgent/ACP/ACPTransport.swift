import Foundation
import Darwin

/// Newline-delimited JSON only. Save the protocol descriptor before routing all
/// existing runtime/library stdout diagnostics to stderr, including C output.
final class ACPTransport: @unchecked Sendable {
    private let output: Int32
    private let lock = NSLock()
    private var outputFailed = false
    private let stopping = AgentCancellation()
    static let maximumFrameBytes = 8 * 1024 * 1024

    init() throws {
        fflush(stdout)
        output = dup(STDOUT_FILENO)
        guard output >= 0 else { throw ACPError.disconnected }
        _ = fcntl(output, F_SETFD, FD_CLOEXEC)
        _ = fcntl(output, F_SETFL, fcntl(output, F_GETFL) | O_NONBLOCK)
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            close(output)
            throw ACPError.disconnected
        }
        signal(SIGPIPE, SIG_IGN)
    }

    deinit { close(output) }

    func stopInput() { stopping.cancel() }

    func send(_ value: JSONValue) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(10)
        lock.withLock {
            guard !outputFailed else { return }
            data.withUnsafeBytes { bytes in
                var offset = 0
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while offset < bytes.count {
                    guard !stopping.isCancelled, ContinuousClock.now < deadline else {
                        outputFailed = true; return
                    }
                    var descriptor = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&descriptor, 1, 100)
                    if ready < 0 && errno == EINTR { continue }
                    if ready == 0 { continue }
                    guard ready > 0 else { outputFailed = true; return }
                    let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    guard count > 0 else { outputFailed = true; return }
                    offset += count
                }
            }
        }
    }

    func frames() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            DispatchQueue(label: "agent.acp.stdin").async {
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    if self.stopping.isCancelled || self.lock.withLock({ self.outputFailed }) { continuation.finish(); return }
                    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&descriptor, 1, 100)
                    if ready < 0 && errno == EINTR { continue }
                    if ready == 0 { continue }
                    guard ready > 0 else { continuation.finish(); return }
                    let count = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { continuation.finish(); return }
                    buffer.append(contentsOf: chunk.prefix(count))
                    while let newline = buffer.firstIndex(of: 10) {
                        let frame = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard frame.count <= Self.maximumFrameBytes else {
                            continuation.finish(throwing: ACPError.invalid("ACP frame too large")); return
                        }
                        if case .dropped = continuation.yield(frame) {
                            continuation.finish(throwing: ACPError.invalid("Too many queued ACP messages")); return
                        }
                    }
                    if buffer.count > Self.maximumFrameBytes {
                        continuation.finish(throwing: ACPError.invalid("ACP frame too large")); return
                    }
                }
            }
        }
    }
}

import Foundation

/// Drains combined output before waiting, so a full pipe cannot block the child.
enum ShellCommand {
    static func run(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

extension ShellCommand {
    static func run(_ command: String, directory: URL, cancellation: AgentCancellation?) async throws -> String {
        let token = cancellation ?? AgentCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try token.check()
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/bin/bash")
                        process.arguments = ["-c", command]
                        process.currentDirectoryURL = directory
                        process.standardInput = FileHandle.nullDevice
                        let output = Pipe()
                        process.standardOutput = output
                        process.standardError = output
                        try process.run()
                        try? output.fileHandleForWriting.close()
                        ProcessIO.nonblocking(output.fileHandleForReading)
                        defer {
                            ProcessIO.stop(process)
                            try? output.fileHandleForReading.close()
                        }
                        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
                        var collected = Data()
                        var truncated = false
                        while let chunk = try ProcessIO.read(from: output.fileHandleForReading, cancellation: token, deadline: deadline) {
                            let remaining = max(0, 256 * 1024 - collected.count)
                            collected.append(chunk.prefix(remaining))
                            if chunk.count > remaining { truncated = true }
                        }
                        while process.isRunning {
                            try ProcessIO.check(token, deadline: deadline)
                            Thread.sleep(forTimeInterval: 0.02)
                        }
                        var result = String(decoding: collected, as: UTF8.self)
                        if truncated { result += "\n[Output truncated]" }
                        if process.terminationStatus != 0 { result += "\n[Exit status: \(process.terminationStatus)]" }
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { token.cancel() }
    }
}

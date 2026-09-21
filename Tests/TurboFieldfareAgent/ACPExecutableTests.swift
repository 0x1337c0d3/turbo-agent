import XCTest
@testable import TurboFieldfareAgentCore

final class ACPExecutableTests: XCTestCase, @unchecked Sendable {
    func testExecutableHandshakeAndSkillsDoNotLoadModelOrContaminateStdout() throws {
        try runExecutable(stopWithSignal: false)
    }

    func testExecutableTerminatesCleanlyOnSIGTERM() throws {
        try runExecutable(stopWithSignal: true)
    }

    private func runExecutable(stopWithSignal: Bool) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/debug/TurboFieldfareAgent")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Agent executable not built at \(executable.path)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".agents/skills"), withIntermediateDirectories: true)
        try "A test skill".write(to: directory.appendingPathComponent(".agents/skills/acp-test.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = executable
        // A successful handshake/skills request must not initialize an inference backend.
        process.arguments = ["--acp", "--backend", "openai"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        ProcessIO.nonblocking(output.fileHandleForReading)
        var buffer = Data()
        let token = AgentCancellation()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        defer { ProcessIO.stop(process) }

        func send(_ method: String, id: Int64, params: ACPObject) throws {
            var data = try JSONEncoder().encode(JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .integer(id), "method": .string(method), "params": .object(params)
            ]))
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func read() throws -> JSONValue {
            while buffer.firstIndex(of: 10) == nil {
                guard let bytes = try ProcessIO.read(from: output.fileHandleForReading, cancellation: token, deadline: deadline) else {
                    throw ACPError.disconnected
                }
                buffer.append(bytes)
            }
            let newline = buffer.firstIndex(of: 10)!
            let frame = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            // Any ANSI/loading logs on protocol stdout fail JSON decoding here.
            return try JSONDecoder().decode(JSONValue.self, from: frame)
        }
        try send("initialize", id: 1, params: ["protocolVersion": .integer(1), "clientCapabilities": .object([:])])
        XCTAssertEqual(try read()["result"]?["protocolVersion"], .integer(1))
        try send("session/new", id: 2, params: ["cwd": .string(directory.path), "mcpServers": .array([])])
        let session = try XCTUnwrap(read()["result"]?["sessionId"]?.string)
        let commands = try read()["params"]?["update"]?["availableCommands"]?.array ?? []
        XCTAssertTrue(commands.contains { $0["name"]?.string == "acp-test" })
        try send("session/prompt", id: 3, params: ["sessionId": .string(session), "prompt": .array([
            .object(["type": .string("text"), "text": .string("/skills")])])])
        XCTAssertTrue(try read()["params"]?["update"]?["content"]?["text"]?.string?.contains("/acp-test") == true)
        XCTAssertEqual(try read()["result"]?["stopReason"]?.string, "end_turn")
        if stopWithSignal { process.terminate() }
        else { try input.fileHandleForWriting.close() }
        while process.isRunning {
            try ProcessIO.check(token, deadline: deadline)
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(process.terminationStatus, 0)
        let diagnostics = String(decoding: try errors.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        XCTAssertFalse(diagnostics.contains("No inference backend"))
    }

    func testCoreKeepsProjectSkillsSeparateWithoutLoadingModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = AgentCore(arguments: ["--backend", "openai"])
        for name in ["project-a", "project-b"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            let skills = directory.appendingPathComponent(".agents/skills")
            try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
            try "test".write(to: skills.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
            let names = try await core.newSession(id: name, directory: directory, servers: [:])
            XCTAssertTrue(names.contains(name))
            XCTAssertFalse(names.contains(name == "project-a" ? "project-b" : "project-a"))
        }
    }
}

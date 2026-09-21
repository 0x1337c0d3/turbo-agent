import Foundation
import XCTest
@testable import TurboAgentCore

final class SkillLoadingTests: XCTestCase, @unchecked Sendable {
    func testCustomSystemPromptReplacesDefaultPrompts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        let customPrompt = root.appendingPathComponent("custom-prompt.md")
        func write(_ text: String, _ path: URL) throws {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: path, atomically: true, encoding: .utf8)
        }
        try write("HOME_DEFAULT", home.appendingPathComponent(".agents/codex_prompt.md"))
        try write("PROJECT_DEFAULT", project.appendingPathComponent(".agents/codex_prompt.md"))
        try write("PROJECT_GUIDANCE", project.appendingPathComponent("AGENTS.md"))
        try write("CUSTOM_SYSTEM_PROMPT", customPrompt)

        let config = try AgentConfig(
            arguments: ["--system-prompt", customPrompt.path],
            homeDirectory: home,
            workingDirectory: project)

        XCTAssertTrue(config.systemPrompt.contains("CUSTOM_SYSTEM_PROMPT"))
        XCTAssertTrue(config.systemPrompt.contains("PROJECT_GUIDANCE"))
        XCTAssertTrue(config.systemPrompt.contains("## Skills"))
        XCTAssertTrue(config.systemPrompt.contains("## MCP Tools"))
        XCTAssertFalse(config.systemPrompt.contains("HOME_DEFAULT"))
        XCTAssertFalse(config.systemPrompt.contains("PROJECT_DEFAULT"))
    }

    func testSkillLibraryDoesNotInflateStartupPrompt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        func write(_ text: String, _ path: URL) throws {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: path, atomically: true, encoding: .utf8)
        }
        try write("HOME_GUIDANCE", home.appendingPathComponent(".agents/codex_prompt.md"))
        try write("PROJECT_GUIDANCE", project.appendingPathComponent("AGENTS.md"))
        let before = try AgentConfig(arguments: [], homeDirectory: home, workingDirectory: project)
        try write(String(repeating: "SKILL_BODY ", count: 100_000), home.appendingPathComponent(".agents/skills/review/SKILL.md"))
        try write(String(repeating: "REFERENCE_BODY ", count: 100_000), home.appendingPathComponent(".agents/skills/review/references/guide.md"))
        try write("LEGACY_BODY", project.appendingPathComponent(".agents/skills/legacy.md"))
        let after = try AgentConfig(arguments: [], homeDirectory: home, workingDirectory: project)
        XCTAssertEqual(after.systemPrompt, before.systemPrompt)
        XCTAssertTrue(after.systemPrompt.contains("HOME_GUIDANCE"))
        XCTAssertTrue(after.systemPrompt.contains("PROJECT_GUIDANCE"))
        XCTAssertFalse(after.systemPrompt.contains("SKILL_BODY"))
        let skills = SkillLibrary.discover(roots: [home.appendingPathComponent(".agents/skills"), project.appendingPathComponent(".agents/skills")])
        XCTAssertEqual(Set(skills.keys), ["review", "legacy"])
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(skills["legacy"]), encoding: .utf8), "LEGACY_BODY")
    }

    func testDiscoveryRetainsHomePrecedenceAndNestedEntryPoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let local = root.appendingPathComponent("local")
        for path in ["home/review.md", "local/review.md", "local/plugin/skills/audit/SKILL.md", "local/plugin/README.md"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "instructions".write(to: file, atomically: true, encoding: .utf8)
        }
        let skills = SkillLibrary.discover(roots: [home, local])
        XCTAssertEqual(Set(skills.keys), ["review", "plugin/skills/audit"])
        XCTAssertTrue(try XCTUnwrap(skills["review"]).path.hasSuffix("/home/review.md"))
    }

}

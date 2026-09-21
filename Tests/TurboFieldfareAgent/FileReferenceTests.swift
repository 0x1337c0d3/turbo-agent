import Foundation
import XCTest
@testable import TurboFieldfareAgentCore

final class FileReferenceTests: XCTestCase {
    func testSyntaxAndLiteralMentions() throws {
        XCTAssertEqual(try FileReferences.paths(in: "Read @one\n@\"two words\" @'three words' @~/four"),
                       ["one", "two words", "three words", "~/four"])
        XCTAssertEqual(try FileReferences.paths(in: "a@b.com \\@literal `@code` @"), [])
        XCTAssertThrowsError(try FileReferences.paths(in: "@\"unfinished"))
        XCTAssertThrowsError(try FileReferences.paths(in: "@''"))
    }

    func testAttachmentsAreDeduplicatedAndNotRecursivelyExpanded() throws {
        try withDirectory { directory in
            try "hello @missing".write(to: directory.appendingPathComponent("one"), atomically: true, encoding: .utf8)
            let context = try FileReferences.context(in: "@one @./one", directory: directory)
            XCTAssertEqual(context.components(separatedBy: "[File reference:").count, 2)
            XCTAssertTrue(context.contains("hello @missing"))
            XCTAssertEqual(try FileReferences.context(in: "hello", directory: directory), "")
            XCTAssertThrowsError(try FileReferences.context(in: "@missing", directory: directory))
            XCTAssertThrowsError(try FileReferences.context(in: "@.", directory: directory))
        }
    }

    func testBinaryAndCombinedSizeLimits() throws {
        try withDirectory { directory in
            try Data([0, 1]).write(to: directory.appendingPathComponent("binary"))
            XCTAssertThrowsError(try FileReferences.context(in: "@binary", directory: directory))
            try Data(repeating: 65, count: FileReferences.maximumBytes).write(to: directory.appendingPathComponent("large"))
            try "x".write(to: directory.appendingPathComponent("small"), atomically: true, encoding: .utf8)
            XCTAssertNoThrow(try FileReferences.context(in: "@large", directory: directory))
            XCTAssertThrowsError(try FileReferences.context(in: "@large @small", directory: directory))
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

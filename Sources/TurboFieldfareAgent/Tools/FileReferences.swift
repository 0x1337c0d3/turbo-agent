import Foundation

/// Explicit REPL attachments. Parse the user's text once, never attached files or skill bodies.
enum FileReferences {
    static let maximumBytes = 256 * 1024
    static let maximumFiles = 16

    struct ReferenceError: Error, CustomStringConvertible {
        let description: String
    }

    static func context(in text: String, directory: URL) throws -> String {
        let paths = try paths(in: text)
        var seen = Set<String>()
        var attachments: [String] = []
        var remaining = maximumBytes
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            let file = URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL
            guard seen.insert(file.path).inserted else { continue }
            guard seen.count <= maximumFiles else {
                throw ReferenceError(description: "At most \(maximumFiles) file references are allowed per prompt.")
            }
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else {
                    throw ReferenceError(description: "Only regular text files can be attached.")
                }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: remaining + 1) ?? Data()
                guard data.count <= remaining else {
                    throw ReferenceError(description: "File references exceed the combined 256 KiB limit.")
                }
                guard !data.contains(0), let body = String(data: data, encoding: .utf8) else {
                    throw ReferenceError(description: "File must contain UTF-8 text without NUL bytes.")
                }
                remaining -= data.count
                attachments.append("[File reference: \(file.path)]\n\(body)\n[End file reference]")
            } catch {
                throw ReferenceError(description: "Cannot attach \(file.path): \(error)")
            }
        }
        return attachments.isEmpty ? "" : "\n\n" + attachments.joined(separator: "\n\n")
    }

    /// References start at a whitespace boundary; emails and escaped @ signs stay literal.
    static func paths(in text: String) throws -> [String] {
        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let start = index
            index = text.index(after: index)
            guard text[start] == "@", start == text.startIndex || text[text.index(before: start)].isWhitespace,
                  index < text.endIndex, !text[index].isWhitespace else { continue }
            let quote = text[index]
            if quote == "\"" || quote == "'" {
                index = text.index(after: index)
                let begin = index
                while index < text.endIndex, text[index] != quote { index = text.index(after: index) }
                guard index < text.endIndex else {
                    throw ReferenceError(description: "Unclosed quoted file reference. Use @\"path with spaces\".")
                }
                let path = String(text[begin..<index])
                guard !path.isEmpty else { throw ReferenceError(description: "File reference path is empty.") }
                result.append(path)
                index = text.index(after: index)
            } else {
                let begin = index
                while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
                result.append(String(text[begin..<index]))
            }
        }
        return result
    }
}

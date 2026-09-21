import Foundation

/// Discovers entry points without reading skill bodies or reference documents.
enum SkillLibrary {
    static func expand(_ text: String, skills: [String: URL]) throws -> String {
        guard text.hasPrefix("/") else { return text }
        let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let name = parts.first.map(String.init), let file = skills[name] else { return text }
        let body = try String(contentsOf: file, encoding: .utf8)
        let request = parts.count > 1 ? String(parts[1]) : ""
        return "[Skill: \(name), source: \(file.path)]\n\(body)\n\nUser Request:\n\(request)"
    }

    static func discover(roots: [URL]) -> [String: URL] {
        let fm = FileManager.default
        var skills: [String: URL] = [:]
        for suppliedRoot in roots {
            let root = suppliedRoot.resolvingSymlinksInPath().standardizedFileURL
            // Retain legacy top-level <name>.md skills.
            let topLevel = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
            for file in topLevel.sorted(by: { $0.path < $1.path })
                where file.pathExtension == "md" && file.lastPathComponent != "SKILL.md" {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let name = file.deletingPathExtension().lastPathComponent
                if skills[name] == nil { skills[name] = file }
            }
            guard let enumerator = fm.enumerator(atPath: root.path) else { continue }
            var entryPoints: [String] = []
            for case let relative as String in enumerator {
                if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                    enumerator.skipDescendants()
                    continue
                }
                if relative.hasSuffix("/SKILL.md") { entryPoints.append(relative) }
            }
            for relative in entryPoints.sorted() {
                let file = root.appendingPathComponent(relative)
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let name = String(relative.dropLast("/SKILL.md".count))
                if skills[name] == nil { skills[name] = file }
            }
        }
        return skills
    }
}

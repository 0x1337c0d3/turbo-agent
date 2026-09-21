import Foundation

/// Retain text layout but render control bytes visibly, including split escape sequences.
enum TerminalText {
    static func safe(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            if scalar == "\n" || scalar == "\t" { return String(scalar) }
            if scalar.value < 32 || (127...159).contains(scalar.value)
                || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) {
                return String(format: "\\u{%04X}", scalar.value)
            }
            return String(scalar)
        }.joined()
    }
}

import Foundation

enum ReadableHTML {
    static func text(from html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?is)<script.*?>.*?</script>", with: "", options: [.regularExpression])
        text = text.replacingOccurrences(of: "(?is)<style.*?>.*?</style>", with: "", options: [.regularExpression])
        text = text.replacingOccurrences(of: "(?is)<svg.*?>.*?</svg>", with: "", options: [.regularExpression])
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: [.regularExpression])
        text = text.replacingOccurrences(of: "(?i)</p>", with: "\n\n", options: [.regularExpression])
        text = text.replacingOccurrences(of: "(?i)</div>", with: "\n", options: [.regularExpression])
        text = text.replacingOccurrences(of: "(?i)</h1>", with: "\n\n", options: [.regularExpression])
        text = text.replacingOccurrences(of: "(?i)</h2>", with: "\n\n", options: [.regularExpression])
        text = text.replacingOccurrences(of: "(?i)</li>", with: "\n", options: [.regularExpression])
        text = text.replacingOccurrences(of: "(?i)<li>", with: "- ", options: [.regularExpression])
        text = text.replacingOccurrences(of: "(?i)<a[^>]+href=\"([^\"]+)\"[^>]*>(.*?)</a>", with: "[$2]($1)", options: [.regularExpression])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression])
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: " {2,}", with: " ", options: [.regularExpression])
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: [.regularExpression])
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

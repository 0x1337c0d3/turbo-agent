import Foundation

/// Authenticated MCP requests must stay on the configured origin, including redirects.
enum MCPNetworkPolicy {
    static func sameOrigin(_ candidate: URL, as origin: URL) -> Bool {
        guard let scheme = candidate.scheme?.lowercased(), ["http", "https"].contains(scheme),
              candidate.user == nil, candidate.password == nil,
              let host = candidate.host?.lowercased(), !host.isEmpty else { return false }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return scheme == origin.scheme?.lowercased() && host == origin.host?.lowercased()
            && port(candidate) == port(origin)
    }

    static func session() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: MCPRedirectPolicy(), delegateQueue: nil)
    }
}

private final class MCPRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let origin = task.originalRequest?.url, let destination = request.url,
              MCPNetworkPolicy.sameOrigin(destination, as: origin) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

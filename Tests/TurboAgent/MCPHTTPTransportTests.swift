import Foundation
import XCTest
@testable import TurboAgentCore

private final class MockMCPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-token")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")
            let method = body["method"] as? String
            var headers = ["Content-Type": "application/json"]
            var result: [String: Any] = [:]
            var status = 200
            switch method {
            case "initialize":
                XCTAssertNil(request.value(forHTTPHeaderField: "Mcp-Session-Id"))
                headers["Mcp-Session-Id"] = "test-session"
                result = ["protocolVersion": "2025-03-26", "capabilities": [:] as [String: String]]
            case "notifications/initialized":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "test-session")
                status = 202
            case "tools/list":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "test-session")
                XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-03-26")
                result = ["tools": [["name": "example", "inputSchema": ["type": "object"]]]]
            case "tools/call":
                let params = try XCTUnwrap(body["params"] as? [String: Any])
                let args = try XCTUnwrap(params["arguments"] as? [String: Any])
                XCTAssertEqual(args["limit"] as? Int, 3)
                XCTAssertEqual(args["enabled"] as? Bool, true)
                result = ["content": [["type": "text", "text": "first"], ["type": "text", "text": "second"]]]
            default: XCTFail("Unexpected MCP method")
            }
            var responseData = Data()
            if status != 202 {
                responseData = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": body["id"]!, "result": result])
                if request.url?.path == "/sse" {
                    headers["Content-Type"] = "text/event-stream"
                    responseData = Data((": heartbeat\n\nevent: message\ndata: " + String(decoding: responseData, as: UTF8.self) + "\n\n").utf8)
                }
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class MCPHTTPTransportTests: XCTestCase, @unchecked Sendable {
    func testHandshakeAndToolCallsWithJSONAndSSEResponses() async {
        for path in ["json", "sse"] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockMCPProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let transport = MCPHTTPTransport(name: "test", url: URL(string: "https://example.invalid/\(path)")!, headers: ["authorization": "Bearer fake-token"], session: session)
            let tools = await transport.listTools()
            XCTAssertEqual(tools.map(\.name), ["example"])
            let result = await transport.callTool(name: "example", argsJson: #"{"limit":3,"enabled":true}"#)
            XCTAssertEqual(result, "first\nsecond")
        }
    }
}

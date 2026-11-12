import Foundation

// The Model Context Protocol (MCP) plumbing for AI agents: a minimal HTTP/1.1 parser and a JSON-RPC dispatcher.
// No app state lives here, so it can be tested on its own. See AgentServer.swift for the listener and AgentTools.swift for the tools.

struct HTTPRequest: Equatable {
    var method: String
    var path: String
    /// Header names are lower-cased.
    var headers: [String: String]
    var body: Data

    enum ParseResult: Equatable {
        case incomplete
        case invalid(String)
        case complete(HTTPRequest)
    }

    static let maxHeaderBytes = 16_384
    static let maxBodyBytes = 2_000_000

    /// Parses one request from the bytes received so far.
    static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .invalid("Headers too large") : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid("Unreadable headers") }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid("Malformed request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = data[headerEnd.upperBound...]
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch dechunk(Data(rest)) {
            case .incomplete: return .incomplete
            case .invalid(let reason): return .invalid(reason)
            case .complete(let decoded): body = decoded
            }
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0 else { return .invalid("Bad Content-Length") }
            guard length <= maxBodyBytes else { return .invalid("Request too large") }
            guard rest.count >= length else { return .incomplete }
            body = Data(rest.prefix(length))
        }
        guard body.count <= maxBodyBytes else { return .invalid("Request too large") }
        let path = String(requestLine[1]).components(separatedBy: "?")[0]
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: body))
    }

    private enum Dechunked { case incomplete, invalid(String), complete(Data) }

    private static func dechunk(_ data: Data) -> Dechunked {
        var output = Data(), index = data.startIndex
        while true {
            guard let lineEnd = data[index...].range(of: Data("\r\n".utf8)) else { return .incomplete }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return .invalid("Bad chunk size") }
            let start = lineEnd.upperBound
            if size == 0 { return .complete(output) }
            guard data.distance(from: start, to: data.endIndex) >= size + 2 else { return .incomplete }
            let end = data.index(start, offsetBy: size)
            output.append(data[start..<end])
            guard output.count <= maxBodyBytes else { return .invalid("Request too large") }
            index = data.index(end, offsetBy: 2)
        }
    }
}

struct HTTPResponse: Equatable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        var all = headers
        all["Content-Type"] = "application/json"
        return HTTPResponse(status: status, headers: all, body: data)
    }

    static func text(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(message.utf8))
    }

    var serialized: Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var all = headers
        all["Content-Length"] = "\(body.count)"
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// The result of one tool call: a JSON-compatible value, or an error message the agent can read and act on.
enum ToolOutcome {
    case success(Any)
    case failure(String)
}

/// A tool an agent can call.
struct AgentToolSpec {
    let name: String
    let description: String
    /// A JSON Schema object for the arguments.
    let inputSchema: [String: Any]
}

/// Answers MCP JSON-RPC messages: initialize, ping, tools/list, and tools/call.
struct MCPDispatcher {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let serverName: String
    let serverVersion: String
    let instructions: String
    let tools: [AgentToolSpec]
    /// Runs a tool. Called on whatever thread the dispatcher runs on.
    let call: (_ name: String, _ arguments: [String: Any]) -> ToolOutcome

    /// Handles a request body: one message or a batch. Returns nil when there's nothing to send back (only notifications).
    func handle(_ body: Data) -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: body) else {
            return encode(Self.error(id: NSNull(), code: -32700, message: "Parse error: the body isn't valid JSON."))
        }
        if let batch = parsed as? [Any] {
            let replies = batch.compactMap { respond(to: $0) }
            return replies.isEmpty ? nil : encode(replies)
        }
        return respond(to: parsed).map(encode)
    }

    /// Whether a message is a request that expects a reply (rather than a notification or a response).
    static func isRequest(_ message: Any) -> Bool {
        guard let object = message as? [String: Any] else { return false }
        return object["method"] != nil && object["id"] != nil
    }

    func respond(to message: Any) -> [String: Any]? {
        guard let object = message as? [String: Any], let method = object["method"] as? String else {
            if let object = message as? [String: Any], object["result"] != nil || object["error"] != nil { return nil } // a client's response: nothing to say
            return Self.error(id: NSNull(), code: -32600, message: "Invalid request.")
        }
        guard let id = object["id"], !(id is NSNull) else { return nil } // a notification
        let params = object["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return Self.result(id: id, [
                "protocolVersion": Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": serverName, "version": serverVersion],
                "instructions": instructions,
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] }])
        case "tools/call":
            guard let name = params["name"] as? String, tools.contains(where: { $0.name == name }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool. Call tools/list to see what's available.")
            }
            switch call(name, params["arguments"] as? [String: Any] ?? [:]) {
            case .success(let value):
                let text = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
                return Self.result(id: id, ["content": [["type": "text", "text": text]], "isError": false])
            case .failure(let message):
                return Self.result(id: id, ["content": [["type": "text", "text": message]], "isError": true])
            }
        case "resources/list": return Self.result(id: id, ["resources": []])
        case "prompts/list": return Self.result(id: id, ["prompts": []])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static func result(id: Any, _ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }

    static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
    }
}

/// Why a request to the agent endpoint is turned away, or nil when it may go ahead. Requests must be for /mcp, carry the
/// access key, be addressed to this Mac (a guard against DNS rebinding), and not come from a web page (browsers send Origin).
func refuse(_ request: HTTPRequest, port: UInt16, token: String) -> HTTPResponse? {
    guard request.path == "/mcp" || request.path == "/" else { return .text(404, "Not found. The MCP endpoint is /mcp.") }
    if request.headers["origin"] != nil { return .text(403, "Requests from web pages aren't allowed.") }
    if let host = request.headers["host"], !["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"].contains(host.lowercased()) {
        return .text(403, "Unexpected host.")
    }
    let presented = request.headers["authorization"].map { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : $0 } ?? ""
    guard !token.isEmpty, constantTimeEqual(presented, token) else {
        return .json(["error": "Missing or wrong access key. Find it in Context → ⚙ → AI Agents."], status: 401, headers: ["WWW-Authenticate": "Bearer"])
    }
    return nil
}

/// Compares secrets in constant time, so response timing doesn't reveal how much of a key was right.
func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var difference: UInt8 = 0
    for index in x.indices { difference |= x[index] ^ y[index] }
    return difference == 0
}

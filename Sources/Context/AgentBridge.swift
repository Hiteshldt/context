import Foundation
import Network
import Security

/// Whether AI agents may connect, on which port, and the key they need. Kept in the data folder (readable by this Mac
/// account only) so `Context --mcp`, the bridge agents launch, can find the running app without anyone pasting a key.
struct AgentSettings: Codable, Equatable {
    var enabled = false
    var port: UInt16 = 47_321
    var token = AgentSettings.newToken()

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static var directory: URL {
        ProcessInfo.processInfo.environment["CONTEXT_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Context", isDirectory: true)
    }
    static var file: URL { directory.appendingPathComponent("agent-access.json") }

    static func load() -> AgentSettings {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(AgentSettings.self, from: $0) } ?? AgentSettings()
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }
}

/// A small HTTP server on this Mac's loopback interface, for MCP's Streamable HTTP transport.
final class AgentHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.context.agent-server")
    private var listener: NWListener?
    private let handler: (HTTPRequest) -> HTTPResponse

    init(handler: @escaping (HTTPRequest) -> HTTPResponse) { self.handler = handler }

    /// Starts listening. `ready` is called with nil once listening, or with what went wrong.
    func start(port: UInt16, ready: @escaping (String?) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { ready("Invalid port"); return }
        do {
            let listener = try NWListener(using: parameters, on: nwPort)
            var reported = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if !reported { reported = true; ready(nil) }
                case .failed(let error): if !reported { reported = true; ready(error.localizedDescription) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            ready(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        // Only programs on this Mac.
        if case .hostPort(let host, _) = connection.endpoint {
            let address = "\(host)"
            guard address.hasPrefix("127.") || address.hasPrefix("::1") || address == "localhost" else { connection.cancel(); return }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request): self.send(self.handler(request), on: connection)
            case .invalid(let reason): self.send(.text(reason.contains("large") ? 413 : 400, reason), on: connection)
            case .incomplete:
                if complete || error != nil { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// `Context --mcp`: the stdio MCP server agents launch. It passes each message to the running app over the local HTTP
/// endpoint, reading the port and key from the data folder, and opens Context in the background if it isn't running.
enum AgentBridge {
    static func run() -> Never {
        var session: String?
        while let line = readLine(strippingNewline: true) {
            let message = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { continue }
            let (reply, newSession) = forward(message, session: session)
            if let newSession { session = newSession }
            if let reply { FileHandle.standardOutput.write(Data((reply + "\n").utf8)) }
        }
        exit(0)
    }

    /// `Context --call <tool> '<json>'`: one tool call from a shell, for agents that run commands rather than MCP.
    /// Prints the result (JSON) and exits 0, or prints the problem to standard error and exits 1.
    /// `Context --call list_tools` lists every tool and its arguments. Pass `-` to read the JSON from standard input.
    static func call(_ arguments: [String]) -> Never {
        func fail(_ message: String, code: Int32 = 1) -> Never {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(code)
        }
        guard let tool = arguments.first, !tool.hasPrefix("-") else {
            fail("Usage: Context --call <tool> '<json arguments>'   (Context --call list_tools shows every tool)", code: 2)
        }
        var message: [String: Any] = ["jsonrpc": "2.0", "id": 1]
        if tool == "list_tools" || tool == "help" {
            message["method"] = "tools/list"
        } else {
            var raw = arguments.dropFirst().joined(separator: " ")
            if raw == "-" { raw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
            var parameters: [String: Any] = [:]
            if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
                    fail("The arguments must be one JSON object, e.g. '{\"project\": \"Ayuvam\"}'.", code: 2)
                }
                parameters = parsed
            }
            message["method"] = "tools/call"
            message["params"] = ["name": tool, "arguments": parameters]
        }
        guard let line = (try? JSONSerialization.data(withJSONObject: message)).map({ String(decoding: $0, as: UTF8.self) }),
              let reply = forward(line, session: nil).0,
              let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] else {
            fail("No reply from Context.")
        }
        if let error = object["error"] as? [String: Any] { fail(error["message"] as? String ?? "Context reported an error.") }
        let result = object["result"] as? [String: Any] ?? [:]
        if let tools = result["tools"] as? [[String: Any]] {
            for tool in tools {
                let schema = tool["inputSchema"] as? [String: Any]
                let required = Set(schema?["required"] as? [String] ?? [])
                let names = ((schema?["properties"] as? [String: Any])?.keys.sorted() ?? []).map { required.contains($0) ? "\($0)*" : $0 }
                print("\(tool["name"] as? String ?? "")\n  \(tool["description"] as? String ?? "")")
                if !names.isEmpty { print("  arguments: \(names.joined(separator: ", "))   (* required)") }
            }
            exit(0)
        }
        let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
        if result["isError"] as? Bool == true { fail(text) }
        print(text)
        exit(0)
    }

    static func forward(_ message: String, session: String?) -> (String?, String?) {
        let settings = AgentSettings.load()
        guard settings.enabled else {
            return (errorReply(for: message, "AI agent access is turned off in Context. Open Context → ⚙ → AI Agents and turn it on."), nil)
        }
        var result = post(message, settings: settings, session: session)
        if case .unreachable = result {
            // Context isn't running: open it in the background and wait for it to start listening.
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-b", "local.context.workspace"]
            try? open.run()
            open.waitUntilExit()
            for _ in 0..<40 {
                Thread.sleep(forTimeInterval: 0.25)
                result = post(message, settings: AgentSettings.load(), session: session)
                if case .unreachable = result { continue }
                break
            }
        }
        switch result {
        case .reply(let body, let newSession): return (body, newSession)
        case .accepted: return (nil, nil)
        case .refused(let reason): return (errorReply(for: message, reason), nil)
        case .unreachable: return (errorReply(for: message, "Couldn't reach Context. Open Context and check ⚙ → AI Agents is on."), nil)
        }
    }

    enum Outcome { case reply(String, String?), accepted, refused(String), unreachable }

    static func post(_ message: String, settings: AgentSettings, session: String?) -> Outcome {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(settings.port)/mcp")!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = Data(message.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        let done = DispatchSemaphore(value: 0)
        var outcome = Outcome.unreachable
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            guard error == nil, let http = response as? HTTPURLResponse else { return }
            let body = String(decoding: data ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            switch http.statusCode {
            case 200: outcome = .reply(body, http.value(forHTTPHeaderField: "Mcp-Session-Id"))
            case 202, 204: outcome = .accepted
            default: outcome = .refused(body.isEmpty ? "Context refused the request (HTTP \(http.statusCode))." : body)
            }
        }.resume()
        done.wait()
        return outcome
    }

    /// A JSON-RPC error for each request in the message (notifications get no reply).
    static func errorReply(for message: String, _ text: String) -> String? {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(message.utf8)) else { return nil }
        let requests = (parsed as? [Any] ?? [parsed]).compactMap { $0 as? [String: Any] }.filter { MCPDispatcher.isRequest($0) }
        let errors = requests.map { MCPDispatcher.error(id: $0["id"]!, code: -32000, message: text) }
        guard !errors.isEmpty else { return nil }
        let object: Any = parsed is [Any] ? errors : errors[0]
        return (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) }
    }
}

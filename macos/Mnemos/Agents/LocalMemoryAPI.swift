import Foundation
import Network
import Security

enum AgentAPIStatus: Equatable, Sendable {
    case stopped
    case starting
    case running(port: UInt16)
    case failed(String)

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Available"
        case .failed: "Unavailable"
        }
    }

    var detail: String {
        switch self {
        case .stopped: "The local retrieval API is stopped."
        case .starting: "Starting the authenticated loopback listener…"
        case let .running(port): "Authenticated on 127.0.0.1:\(port)"
        case let .failed(message): message
        }
    }
}

actor LocalMemoryAPI {
    private struct APIConfiguration: Encodable {
        let apiVersion: Int
        let baseURL: String
        let bearerToken: String
        let processID: Int32
    }

    private struct APIHealth: Encodable {
        let status: String
        let apiVersion: Int
        let observationCount: Int
        let episodeCount: Int
        let detail: String
    }

    private struct APIError: Encodable {
        let error: String
    }

    private struct APIEnvelope<Value: Encodable>: Encodable {
        let data: Value
    }

    private struct Request {
        let method: String
        let target: String
        let headers: [String: String]
    }

    private struct Response {
        let status: Int
        let reason: String
        let body: Data
    }

    private let memoryStore: SQLiteMemoryStore
    private let queue = DispatchQueue(label: "dev.mnemos.agent-api", qos: .userInitiated)
    private let port: UInt16 = 17_373
    private let maximumRequestBytes = 32 * 1_024
    private let configurationURL: URL
    private var listener: NWListener?
    private var bearerToken = ""
    private var status: AgentAPIStatus = .stopped

    init(memoryStore: SQLiteMemoryStore) {
        self.memoryStore = memoryStore
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        configurationURL = applicationSupport
            .appendingPathComponent("Mnemos", isDirectory: true)
            .appendingPathComponent("agent-api.json", isDirectory: false)
    }

    func start() {
        guard listener == nil else { return }
        status = .starting
        try? FileManager.default.removeItem(at: configurationURL)

        do {
            bearerToken = try Self.generateToken()
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                throw NSError(domain: "MnemosAgentAPI", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid local API port."
                ])
            }

            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
            let listener = try NWListener(using: parameters)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleListenerState(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            listener.start(queue: queue)
        } catch {
            listener = nil
            try? FileManager.default.removeItem(at: configurationURL)
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        bearerToken = ""
        status = .stopped
        try? FileManager.default.removeItem(at: configurationURL)
    }

    func currentStatus() -> AgentAPIStatus {
        status
    }

    func configurationPath() -> String {
        configurationURL.path
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            do {
                try writeConfiguration()
                status = .running(port: port)
            } catch {
                listener?.cancel()
                listener = nil
                status = .failed("Could not secure the agent configuration: \(error.localizedDescription)")
            }
        case let .failed(error):
            listener = nil
            try? FileManager.default.removeItem(at: configurationURL)
            status = .failed(error.localizedDescription)
        case .cancelled:
            if case .failed = status { return }
            status = .stopped
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            Task {
                guard let self else {
                    connection.cancel()
                    return
                }
                await self.handleReceived(
                    data: data,
                    on: connection,
                    accumulated: accumulated,
                    isComplete: isComplete,
                    error: error
                )
            }
        }
    }

    private func handleReceived(
        data: Data?,
        on connection: NWConnection,
        accumulated: Data,
        isComplete: Bool,
        error: NWError?
    ) async {
        if error != nil {
            connection.cancel()
            return
        }

        var requestData = accumulated
        if let data { requestData.append(data) }
        guard requestData.count <= maximumRequestBytes else {
            send(errorResponse(status: 413, reason: "Payload Too Large", message: "Request headers are too large."), on: connection)
            return
        }

        if requestData.range(of: Data("\r\n\r\n".utf8)) == nil {
            if isComplete {
                send(errorResponse(status: 400, reason: "Bad Request", message: "Incomplete HTTP request."), on: connection)
            } else {
                receive(on: connection, accumulated: requestData)
            }
            return
        }

        guard let request = parseRequest(requestData) else {
            send(errorResponse(status: 400, reason: "Bad Request", message: "Malformed HTTP request."), on: connection)
            return
        }
        let response = await route(request)
        send(response, on: connection)
    }

    private func parseRequest(_ data: Data) -> Request? {
        guard let headerText = String(data: data, encoding: .utf8),
              let headerEnd = headerText.range(of: "\r\n\r\n") else { return nil }
        let lines = headerText[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[2].hasPrefix("HTTP/1.") else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            headers[name] = value
        }
        return Request(method: String(requestParts[0]), target: String(requestParts[1]), headers: headers)
    }

    private func route(_ request: Request) async -> Response {
        guard request.method == "GET" else {
            return errorResponse(status: 405, reason: "Method Not Allowed", message: "This API is read-only.")
        }
        guard let authorization = request.headers["authorization"],
              Self.constantTimeEqual(authorization, "Bearer \(bearerToken)") else {
            return errorResponse(status: 401, reason: "Unauthorized", message: "A valid bearer token is required.")
        }
        guard let components = URLComponents(string: "http://127.0.0.1\(request.target)") else {
            return errorResponse(status: 400, reason: "Bad Request", message: "Invalid request target.")
        }

        let path = components.path
        let queryItems = Dictionary(
            components.queryItems?.compactMap { item in item.value.map { (item.name, $0) } } ?? [],
            uniquingKeysWith: { first, _ in first }
        )

        do {
            switch path {
            case "/v1/health":
                let health = await memoryStore.health()
                let state: String
                if case .ready = health.state { state = "ok" } else { state = "unavailable" }
                return try jsonResponse(
                    APIHealth(
                        status: state,
                        apiVersion: 1,
                        observationCount: health.observationCount,
                        episodeCount: health.episodeCount,
                        detail: health.detail
                    )
                )

            case "/v1/episodes/recent":
                let limit = Self.boundedLimit(queryItems["limit"], defaultValue: 20, maximum: 50)
                return try jsonResponse(APIEnvelope(data: try await memoryStore.recentEpisodes(limit: limit)))

            case "/v1/search":
                guard let query = queryItems["q"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !query.isEmpty else {
                    return errorResponse(status: 400, reason: "Bad Request", message: "The q parameter is required.")
                }
                guard query.count <= 500 else {
                    return errorResponse(status: 400, reason: "Bad Request", message: "The query must be 500 characters or fewer.")
                }
                let limit = Self.boundedLimit(queryItems["limit"], defaultValue: 10, maximum: 50)
                return try jsonResponse(APIEnvelope(data: try await memoryStore.search(query, limit: limit)))

            default:
                let segments = path.split(separator: "/").map(String.init)
                guard segments.count >= 3,
                      segments[0] == "v1",
                      segments[1] == "episodes",
                      let episodeID = segments[2].removingPercentEncoding,
                      !episodeID.isEmpty else {
                    return errorResponse(status: 404, reason: "Not Found", message: "Unknown endpoint.")
                }

                if segments.count == 3 {
                    guard let episode = try await memoryStore.episode(id: episodeID) else {
                        return errorResponse(status: 404, reason: "Not Found", message: "Episode not found.")
                    }
                    return try jsonResponse(APIEnvelope(data: episode))
                }

                if segments.count == 4, segments[3] == "evidence" {
                    let limit = Self.boundedLimit(queryItems["limit"], defaultValue: 100, maximum: 200)
                    guard try await memoryStore.episode(id: episodeID) != nil else {
                        return errorResponse(status: 404, reason: "Not Found", message: "Episode not found.")
                    }
                    return try jsonResponse(APIEnvelope(data: try await memoryStore.evidence(for: episodeID, limit: limit)))
                }

                return errorResponse(status: 404, reason: "Not Found", message: "Unknown endpoint.")
            }
        } catch {
            return errorResponse(status: 500, reason: "Internal Server Error", message: "Memory retrieval failed.")
        }
    }

    private func jsonResponse<Value: Encodable>(_ value: Value) throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Response(status: 200, reason: "OK", body: try encoder.encode(value))
    }

    private func errorResponse(status: Int, reason: String, message: String) -> Response {
        let body = (try? JSONEncoder().encode(APIError(error: message))) ?? Data("{\"error\":\"Request failed.\"}".utf8)
        return Response(status: status, reason: reason, body: body)
    }

    private func send(_ response: Response, on connection: NWConnection) {
        var data = Data(
            """
            HTTP/1.1 \(response.status) \(response.reason)\r
            Content-Type: application/json; charset=utf-8\r
            Content-Length: \(response.body.count)\r
            Cache-Control: no-store\r
            X-Content-Type-Options: nosniff\r
            Connection: close\r
            \r

            """.utf8
        )
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func writeConfiguration() throws {
        let directory = configurationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let configuration = APIConfiguration(
            apiVersion: 1,
            baseURL: "http://127.0.0.1:\(port)",
            bearerToken: bearerToken,
            processID: ProcessInfo.processInfo.processIdentifier
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(configuration).write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
    }

    private static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: "MnemosAgentAPI", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not generate an authentication token."
            ])
        }
        return Data(bytes).base64EncodedString()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private static func boundedLimit(_ value: String?, defaultValue: Int, maximum: Int) -> Int {
        guard let value, let parsed = Int(value) else { return defaultValue }
        return min(max(parsed, 1), maximum)
    }
}

//
//  OpenCodeClient.swift
//  ClaudeIsland
//
//  Low-level HTTP client for OpenCode server API
//

import Foundation

/// Low-level HTTP client for communicating with the OpenCode server
actor OpenCodeClient {
    
    // MARK: - Configuration
    
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    
    // MARK: - Logging
    
    private func log(_ message: String) {
        print("[OpenCodeClient] \(message)")
    }
    
    // MARK: - Initialization
    
    init(port: Int = 4096, hostname: String = "127.0.0.1") {
        let urlString = "http://\(hostname):\(port)"
        print("[OpenCodeClient] Initializing with URL: \(urlString)")
        guard let url = URL(string: urlString) else {
            fatalError("Invalid OpenCode server URL: \(urlString)")
        }
        self.baseURL = url
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300  // 5 minutes for long-running prompts
        config.timeoutIntervalForResource = 600 // 10 minutes total
        self.session = URLSession(configuration: config)
        
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            // Try ISO8601 with fractional seconds first
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            // Fall back to without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(dateString)"
            )
        }
        
        self.encoder = JSONEncoder()
    }
    
    // MARK: - Health Check
    
    /// Check if the server is running and get version info
    func health() async throws -> HealthResponse {
        try await get("/global/health")
    }
    
    /// Quick check if server is reachable
    func isServerRunning() async -> Bool {
        do {
            _ = try await health()
            return true
        } catch {
            return false
        }
    }
    
    // MARK: - Path
    
    /// Get the server's current working directory
    func getPath() async throws -> PathInfo {
        try await get("/path")
    }
    
    // MARK: - Agents
    
    /// Get list of all available agents
    func listAgents() async throws -> [ServerAgent] {
        try await get("/agent")
    }
    
    // MARK: - Config
    
    /// Get server configuration
    func getConfig() async throws -> ServerConfig {
        try await get("/config")
    }
    
    // MARK: - Providers
    
    /// Get all providers and their models
    func listProviders() async throws -> ProviderListResponse {
        try await get("/provider")
    }
    
    // MARK: - Sessions
    
    /// List all sessions
    func listSessions() async throws -> [Session] {
        try await get("/session")
    }
    
    /// Get a specific session
    func getSession(id: String) async throws -> Session {
        try await get("/session/\(id)")
    }
    
    /// Create a new session
    func createSession(title: String? = nil, parentID: String? = nil) async throws -> Session {
        let request = CreateSessionRequest(title: title, parentID: parentID)
        return try await post("/session", body: request)
    }
    
    /// Delete a session
    func deleteSession(id: String) async throws -> Bool {
        try await delete("/session/\(id)")
    }
    
    /// Abort a running session
    func abortSession(id: String) async throws -> Bool {
        try await post("/session/\(id)/abort", body: EmptyBody())
    }
    
    // MARK: - Messages
    
    /// Get messages in a session
    func listMessages(sessionID: String, limit: Int? = nil) async throws -> [MessageWithParts] {
        var path = "/session/\(sessionID)/message"
        if let limit = limit {
            path += "?limit=\(limit)"
        }
        return try await get(path)
    }
    
    /// Send a prompt and wait for complete response (blocking)
    func sendPrompt(
        sessionID: String,
        text: String,
        agent: String? = nil
    ) async throws -> MessageWithParts {
        let request = PromptRequest(text: text, agent: agent)
        return try await post("/session/\(sessionID)/message", body: request)
    }
    
    /// Send a prompt with multiple parts (text and images) and wait for complete response
    func sendPrompt(
        sessionID: String,
        parts: [PromptPart],
        agent: String? = nil
    ) async throws -> MessageWithParts {
        let request = PromptRequest(parts: parts, agent: agent)
        return try await post("/session/\(sessionID)/message", body: request)
    }
    
    /// Send a prompt asynchronously (non-blocking, use SSE for response)
    func sendPromptAsync(
        sessionID: String,
        text: String,
        agent: String? = nil
    ) async throws {
        let request = PromptRequest(text: text, agent: agent)
        let _: Bool = try await post("/session/\(sessionID)/prompt_async", body: request)
    }
    
    // MARK: - SSE Events
    
    /// Subscribe to server-sent events
    /// Returns an AsyncThrowingStream of SSE events
    func subscribeToEvents() -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = baseURL.appendingPathComponent("/event")
                    var request = URLRequest(url: url)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    
                    let (bytes, response) = try await session.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw OpenCodeError.unknown("Invalid response type")
                    }
                    
                    guard httpResponse.statusCode == 200 else {
                        throw OpenCodeError.httpError(
                            statusCode: httpResponse.statusCode,
                            message: "SSE connection failed"
                        )
                    }
                    
                    var eventType: String?
                    var eventData = Data()
                    
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            // Empty line marks end of event
                            if let type = eventType, !eventData.isEmpty {
                                let event = SSEEvent(type: type, data: eventData)
                                continuation.yield(event)
                            }
                            eventType = nil
                            eventData = Data()
                            continue
                        }
                        
                        if line.hasPrefix("event:") {
                            eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            if let jsonData = data.data(using: .utf8) {
                                eventData.append(jsonData)
                            }
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }
    
    // MARK: - Private Helpers
    
    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        return try await performRequest(request)
    }
    
    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw OpenCodeError.encodingError(error)
        }
        
        return try await performRequest(request)
    }
    
    private func delete<T: Decodable>(_ path: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        return try await performRequest(request)
    }
    
    private func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        
        log("Performing request: \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")")
        
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            log("URLError: \(error.code.rawValue) - \(error.localizedDescription)")
            if error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                throw OpenCodeError.serverNotRunning
            }
            throw OpenCodeError.networkError(error)
        } catch {
            log("Network error: \(error)")
            throw OpenCodeError.networkError(error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            log("Invalid response type (not HTTPURLResponse)")
            throw OpenCodeError.unknown("Invalid response type")
        }
        
        log("Response status: \(httpResponse.statusCode)")
        
        // Log raw response data for debugging
        if let responseString = String(data: data, encoding: .utf8) {
            let preview = responseString.prefix(500)
            log("Response body (\(data.count) bytes): \(preview)\(responseString.count > 500 ? "..." : "")")
        } else {
            log("Response body: \(data.count) bytes (non-UTF8)")
        }
        
        // Handle non-success status codes
        guard (200...299).contains(httpResponse.statusCode) else {
            // Try to extract error message from response
            var message: String?
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                message = errorResponse.error ?? errorResponse.message
            }
            log("HTTP error: \(httpResponse.statusCode), message: \(message ?? "none")")
            throw OpenCodeError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
        
        // Handle empty responses for Bool return types
        if T.self == Bool.self {
            log("Returning true for Bool type")
            // For boolean responses, success means true
            return true as! T
        }
        
        // Handle 204 No Content
        if httpResponse.statusCode == 204 {
            if T.self == Bool.self {
                return true as! T
            }
            log("Unexpected 204 No Content for type \(T.self)")
            throw OpenCodeError.decodingError(
                NSError(domain: "OpenCodeClient", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "Unexpected empty response"
                ])
            )
        }
        
        do {
            log("Decoding response as \(T.self)")
            let result = try decoder.decode(T.self, from: data)
            log("Decode successful")
            return result
        } catch {
            log("Decode FAILED for type \(T.self): \(error)")
            throw OpenCodeError.decodingError(error)
        }
    }
}

// MARK: - Helper Types

private struct EmptyBody: Encodable {}

private struct ErrorResponse: Decodable {
    let error: String?
    let message: String?
}

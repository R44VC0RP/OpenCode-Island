//
//  OpenCodeService.swift
//  OpenCodeIsland
//
//  High-level service for interacting with OpenCode server
//

import Combine
import Foundation

/// Connection state to the OpenCode server
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
    
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Delegate protocol for receiving streaming updates
protocol OpenCodeServiceDelegate: AnyObject {
    func openCodeService(_ service: OpenCodeService, didReceiveStreamingText text: String)
    func openCodeService(_ service: OpenCodeService, didCompleteWithResult result: String)
    func openCodeService(_ service: OpenCodeService, didFailWithError error: Error)
    func openCodeServiceDidStartProcessing(_ service: OpenCodeService)
}

/// High-level service for managing OpenCode server interactions
@MainActor
class OpenCodeService: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var agents: [ServerAgent] = []
    @Published private(set) var providers: [Provider] = []
    @Published private(set) var availableModels: [ModelRef] = []
    @Published private(set) var serverVersion: String?
    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var streamingText: String = ""
    @Published private(set) var conversationHistory: [MessageWithParts] = []
    
    // MARK: - Delegate
    
    weak var delegate: OpenCodeServiceDelegate?
    
    // MARK: - Private State
    
    private var client: OpenCodeClient
    private var activeSessionID: String?
    private var eventTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    
    // MARK: - Logging
    
    private func log(_ message: String) {
        print("[OpenCodeService] \(message)")
    }
    
    // MARK: - Server Manager
    
    private let serverManager = OpenCodeServerManager.shared

    // MARK: - Initialization
    
    init() {
        // Initialize with placeholder port; will be replaced when server starts
        self.client = OpenCodeClient(port: 0, hostname: "127.0.0.1")
        print("[OpenCodeService] Initialized, waiting for server to start")
    }
    
    deinit {
        eventTask?.cancel()
        processingTask?.cancel()
    }
    
    /// Reinitialize client with server manager's port
    func reinitializeClient() {
        let port = serverManager.serverPort
        log("Reinitializing client with port: \(port)")
        self.client = OpenCodeClient(port: port, hostname: "127.0.0.1")
    }
    
    // MARK: - Connection Management
    
    /// The server's current working directory (from server manager)
    var serverWorkingDirectory: String? {
        serverManager.isRunning ? serverManager.workingDirectory : nil
    }
    
    /// Connect to the OpenCode server (always starts dedicated server instance)
    func connect() async {
        // Guard against duplicate connect attempts
        guard connectionState != .connecting else {
            log("Already connecting; ignoring duplicate connect() call.")
            return
        }
        
        log("connect() called, current state: \(connectionState)")
        connectionState = .connecting
        
        do {
            // NOTE: We intentionally do NOT try to reuse an existing server on port 4096.
            // The OpenCode desktop app's web UI listens there and exposes health + sessions
            // but does not return assistant message parts correctly, which causes Island
            // to show empty assistant responses. We always start our own `opencode serve`.
            log("Starting dedicated OpenCode server instance...")
            
            // Start our own server instance
            await serverManager.startServer()
            
            guard serverManager.isRunning else {
                let error = serverManager.errorMessage ?? "Failed to start server"
                log("Server failed to start: \(error)")
                connectionState = .error(error)
                return
            }
            
            // Reinitialize client with the server's port
            reinitializeClient()
            log("Server running on port \(serverManager.serverPort)")
            
            // Check server health
            log("Checking server health...")
            let health = try await client.health()
            serverVersion = health.version
            log("Server health OK, version: \(health.version)")
            
            // Clear any old session since we have a fresh server
            activeSessionID = nil
            
            // Load agents
            log("Loading agents...")
            try await loadAgents()
            log("Loaded \(agents.count) agents")
            
            // Load providers/models
            log("Loading providers...")
            try await loadProviders()
            
            connectionState = .connected
            log("Connection successful! Working directory: \(serverManager.workingDirectory)")
            
            // Start listening to events for streaming
            startEventStream()
            
        } catch let error as OpenCodeError {
            log("Connection failed with OpenCodeError: \(error.errorDescription ?? "unknown")")
            connectionState = .error(error.shortDescription)
        } catch {
            log("Connection failed with error: \(error)")
            connectionState = .error("Connection failed: \(error.localizedDescription)")
        }
    }
    
    /// Disconnect from the server (stops the server)
    func disconnect() {
        log("disconnect() called")
        eventTask?.cancel()
        eventTask = nil
        serverManager.stopServer()
        connectionState = .disconnected
    }
    
    /// Check if server is available without fully connecting
    func checkServerAvailable() async -> Bool {
        let available = await client.isServerRunning()
        log("Server available: \(available)")
        return available
    }
    
    // MARK: - Agents
    
    /// Load available agents from the server
    func loadAgents() async throws {
        let allAgents = try await client.listAgents()
        // Filter to only primary agents (users select these directly)
        agents = allAgents.filter { $0.isPrimary }
    }
    
    /// Get the default agent (first primary agent, or "build" if available)
    var defaultAgent: ServerAgent? {
        // Prefer "build" agent as it's the OpenCode default
        if let build = agents.first(where: { $0.id == "build" }) {
            return build
        }
        // Fall back to first primary agent
        return agents.first
    }
    
    /// Find an agent by ID
    func agent(id: String) -> ServerAgent? {
        agents.first { $0.id == id }
    }
    
    // MARK: - Providers & Models
    
    /// Load available providers and models from the server
    func loadProviders() async throws {
        let response = try await client.listProviders()
        providers = response.all
        
        // Build flat list of available models from connected providers
        var models: [ModelRef] = []
        for provider in providers {
            // Only include models from connected providers
            if response.connected.contains(provider.id) {
                for model in provider.modelsArray {
                    models.append(ModelRef(provider: provider, model: model))
                }
            }
        }
        availableModels = models
        log("Loaded \(availableModels.count) models from \(response.connected.count) connected providers")
    }
    
    /// Find a model by its full ID (providerID/modelID)
    func model(id: String) -> ModelRef? {
        availableModels.first { $0.id == id }
    }
    
    // MARK: - Session Management
    
    /// Get or create an active session
    func getOrCreateSession() async throws -> String {
        // If we have an active session, verify it still exists
        if let sessionID = activeSessionID {
            do {
                _ = try await client.getSession(id: sessionID)
                return sessionID
            } catch {
                // Session doesn't exist, clear it
                activeSessionID = nil
            }
        }
        
        // Create a new session
        let session = try await client.createSession(title: "OpenCode Island")
        activeSessionID = session.id
        log("Created new session: \(session.id) in directory: \(session.directory ?? "unknown")")
        return session.id
    }
    
    /// Start a new session (clear current one)
    func newSession() async throws -> String {
        activeSessionID = nil
        return try await getOrCreateSession()
    }
    
    /// Abort the current processing
    func abort() async {
        processingTask?.cancel()
        processingTask = nil
        
        if let sessionID = activeSessionID {
            do {
                _ = try await client.abortSession(id: sessionID)
            } catch {
                // Ignore abort errors
            }
        }
        
        isProcessing = false
    }
    
    // MARK: - Prompts
    
    /// Submit a prompt and stream the response
    /// - Parameters:
    ///   - text: The prompt text
    ///   - agentID: Optional agent ID (uses default if nil)
    /// - Returns: The complete response text
    @discardableResult
    func submitPrompt(_ text: String, agentID: String? = nil) async throws -> String {
        return try await submitPrompt(parts: [.text(text)], agentID: agentID)
    }
    
    /// Submit a prompt with multiple parts (text and images)
    /// - Parameters:
    ///   - parts: Array of prompt parts (text and/or images)
    ///   - agentID: Optional agent ID to use
    /// - Returns: The complete response text
    @discardableResult
    func submitPrompt(parts: [PromptPart], agentID: String? = nil) async throws -> String {
        guard connectionState.isConnected else {
            throw OpenCodeError.serverNotRunning
        }
        
        isProcessing = true
        streamingText = ""
        delegate?.openCodeServiceDidStartProcessing(self)
        
        do {
            let sessionID = try await getOrCreateSession()
            
            // Send prompt with parts
            let response = try await client.sendPrompt(
                sessionID: sessionID,
                parts: parts,
                agent: agentID
            )
            
            // Extract text from response parts
            let resultText = extractText(from: response.parts)
            
            isProcessing = false
            streamingText = resultText
            
            // Fetch full conversation history after completion
            await fetchConversationHistory()
            
            delegate?.openCodeService(self, didCompleteWithResult: resultText)
            
            return resultText
            
        } catch {
            isProcessing = false
            delegate?.openCodeService(self, didFailWithError: error)
            throw error
        }
    }
    
    /// Submit a prompt asynchronously with streaming updates via delegate
    func submitPromptAsync(_ text: String, agentID: String? = nil) {
        processingTask?.cancel()
        
        processingTask = Task {
            do {
                try await submitPrompt(text, agentID: agentID)
            } catch {
                // Error already reported via delegate
            }
        }
    }
    
    // MARK: - Private Helpers
    
    /// Start the SSE event stream for real-time updates
    private func startEventStream() {
        eventTask?.cancel()
        
        eventTask = Task {
            var retryCount = 0
            let maxRetries = 5
            
            while !Task.isCancelled && retryCount < maxRetries {
                do {
                    log("Starting event stream (attempt \(retryCount + 1))")
                    let events = await client.subscribeToEvents()
                    retryCount = 0  // Reset on successful connection
                    
                    for try await event in events {
                        await handleEvent(event)
                    }
                    
                    // Stream ended normally, try to reconnect
                    if !Task.isCancelled {
                        log("Event stream ended, reconnecting...")
                        try await Task.sleep(for: .seconds(1))
                    }
                } catch {
                    if Task.isCancelled { break }
                    
                    retryCount += 1
                    log("Event stream error (attempt \(retryCount)): \(error)")
                    
                    if retryCount < maxRetries {
                        // Exponential backoff: 1s, 2s, 4s, 8s, 16s
                        let delay = pow(2.0, Double(retryCount - 1))
                        log("Retrying in \(delay) seconds...")
                        try? await Task.sleep(for: .seconds(delay))
                    }
                }
            }
            
            // Only show error if we exhausted retries and not cancelled
            if !Task.isCancelled && retryCount >= maxRetries {
                await MainActor.run {
                    connectionState = .error("Event stream disconnected")
                }
            }
        }
    }
    
    /// Handle an incoming SSE event
    private func handleEvent(_ event: SSEEvent) async {
        let eventType = OpenCodeEventType(rawValue: event.type)
        
        switch eventType {
        case .messagePartUpdated:
            // Handle streaming text and tool updates
            if let partEvent = try? event.decode(MessagePartUpdatedEvent.self) {
                let part = partEvent.properties.part
                
                // Check if this is for our active session
                guard part.sessionID == activeSessionID else { return }
                
                // Handle streaming text deltas
                if part.type == .text, let delta = partEvent.properties.delta {
                    await MainActor.run {
                        self.streamingText += delta
                        self.delegate?.openCodeService(self, didReceiveStreamingText: self.streamingText)
                    }
                }
                
                // Update the part in conversation history for live tool status updates
                await updatePartInHistory(part)
            }
            
        case .messageUpdated:
            // Handle message completion
            if let msgEvent = try? event.decode(MessageUpdatedEvent.self) {
                let message = msgEvent.properties.info
                guard message.sessionID == activeSessionID else { return }
                
                // If message has a finish reason, processing is done
                if message.finish != nil {
                    await MainActor.run {
                        self.isProcessing = false
                    }
                    // Refresh conversation history to get final state
                    await fetchConversationHistory()
                }
            }
            
        case .sessionStatus:
            // Handle session status changes
            if let statusEvent = try? event.decode(SessionStatusEvent.self) {
                if statusEvent.properties.sessionID == activeSessionID {
                    let statusType = statusEvent.properties.status.type
                    if statusType == "idle" {
                        await MainActor.run {
                            self.isProcessing = false
                        }
                        // Fetch final conversation history
                        await fetchConversationHistory()
                    }
                }
            }
            
        case .sessionIdle:
            // Handle session becoming idle
            if let idleEvent = try? event.decode(SessionIdleEvent.self) {
                if idleEvent.properties.sessionID == activeSessionID {
                    await MainActor.run {
                        self.isProcessing = false
                    }
                    // Fetch final conversation history
                    await fetchConversationHistory()
                }
            }
            
        case .sessionError:
            // Handle session errors
            if let errorEvent = try? event.decode(SessionErrorEvent.self) {
                if errorEvent.properties.sessionID == activeSessionID {
                    let errorMessage = errorEvent.properties.error?.data?.message ?? "Unknown error"
                    await MainActor.run {
                        self.isProcessing = false
                        self.delegate?.openCodeService(self, didFailWithError: OpenCodeError.unknown(errorMessage))
                    }
                }
            }
            
        default:
            // Ignore other events
            break
        }
    }
    
    /// Update a part in the conversation history (for live tool status updates)
    private func updatePartInHistory(_ updatedPart: MessagePart) async {
        await MainActor.run {
            // Find the message containing this part
            guard let messageIndex = conversationHistory.firstIndex(where: { $0.info.id == updatedPart.messageID }) else {
                return
            }
            
            // Find and update the part
            var message = conversationHistory[messageIndex]
            if let partIndex = message.parts.firstIndex(where: { $0.id == updatedPart.id }) {
                // Update existing part
                var parts = message.parts
                parts[partIndex] = updatedPart
                message = MessageWithParts(info: message.info, parts: parts)
                conversationHistory[messageIndex] = message
            } else {
                // Add new part
                var parts = message.parts
                parts.append(updatedPart)
                message = MessageWithParts(info: message.info, parts: parts)
                conversationHistory[messageIndex] = message
            }
        }
    }
    
    /// Extract text content from message parts
    private func extractText(from parts: [MessagePart]) -> String {
        parts
            .filter { $0.type == .text }
            .compactMap { $0.text }
            .joined(separator: "\n")
    }
    
    // MARK: - Conversation History
    
    /// Fetch the conversation history for the current session
    func fetchConversationHistory() async {
        guard let sessionID = activeSessionID else {
            log("No active session for fetching history")
            return
        }
        
        do {
            let messages = try await client.listMessages(sessionID: sessionID)
            await MainActor.run {
                self.conversationHistory = messages
            }
            log("Fetched \(messages.count) messages from history")
        } catch {
            log("Failed to fetch conversation history: \(error)")
        }
    }
    
    /// Clear conversation history (e.g., when starting new session)
    func clearConversationHistory() {
        conversationHistory = []
    }
}



//
//  OpenCodeService.swift
//  ClaudeIsland
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
    
    // MARK: - Initialization
    
    init() {
        // Use configured server URL
        let components = AppSettings.serverComponents ?? (host: "127.0.0.1", port: 4096)
        self.client = OpenCodeClient(port: components.port, hostname: components.host)
        print("[OpenCodeService] Initializing with server: \(components.host):\(components.port)")
    }
    
    deinit {
        eventTask?.cancel()
        processingTask?.cancel()
    }
    
    /// Reinitialize with current settings (call after changing server URL)
    func reinitializeClient() {
        let components = AppSettings.serverComponents ?? (host: "127.0.0.1", port: 4096)
        log("Reinitializing client with server: \(components.host):\(components.port)")
        self.client = OpenCodeClient(port: components.port, hostname: components.host)
    }
    
    // MARK: - Connection Management
    
    /// Connect to the OpenCode server
    func connect() async {
        log("connect() called, current state: \(connectionState)")
        connectionState = .connecting
        
        do {
            // Check server health
            log("Checking server health...")
            let health = try await client.health()
            serverVersion = health.version
            log("Server health OK, version: \(health.version)")
            
            // Load agents
            log("Loading agents...")
            try await loadAgents()
            log("Loaded \(agents.count) agents")
            
            // Load providers/models
            log("Loading providers...")
            try await loadProviders()
            
            connectionState = .connected
            log("Connection successful!")
            
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
    
    /// Disconnect from the server
    func disconnect() {
        log("disconnect() called")
        eventTask?.cancel()
        eventTask = nil
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
        // If we have a persisted session ID, try to use it
        if let sessionID = activeSessionID ?? AppSettings.persistedSessionID {
            // Verify the session still exists
            do {
                _ = try await client.getSession(id: sessionID)
                activeSessionID = sessionID
                return sessionID
            } catch {
                // Session doesn't exist, clear it and create new one
                activeSessionID = nil
                AppSettings.persistedSessionID = nil
            }
        }
        
        // Create a new session
        let session = try await client.createSession(title: "OpenCode Island")
        activeSessionID = session.id
        AppSettings.persistedSessionID = session.id
        return session.id
    }
    
    /// Start a new session (clear current one)
    func newSession() async throws -> String {
        activeSessionID = nil
        AppSettings.persistedSessionID = nil
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
            do {
                let events = await client.subscribeToEvents()
                
                for try await event in events {
                    await handleEvent(event)
                }
            } catch {
                // Stream ended or failed
                if !Task.isCancelled {
                    await MainActor.run {
                        connectionState = .error("Event stream disconnected")
                    }
                }
            }
        }
    }
    
    /// Handle an incoming SSE event
    private func handleEvent(_ event: SSEEvent) async {
        let eventType = OpenCodeEventType(rawValue: event.type)
        
        switch eventType {
        case .partUpdated:
            // Handle streaming text updates
            if let partEvent = try? event.decode(PartUpdatedEvent.self) {
                // Check if this is for our active session
                if partEvent.properties.sessionID == activeSessionID {
                    if let text = partEvent.properties.part.text {
                        await MainActor.run {
                            self.streamingText += text
                            self.delegate?.openCodeService(self, didReceiveStreamingText: self.streamingText)
                        }
                    }
                }
            }
            
        case .sessionStatus:
            // Handle session status changes
            if let statusEvent = try? event.decode(SessionStatusEvent.self) {
                if statusEvent.properties.sessionID == activeSessionID {
                    let status = statusEvent.properties.status
                    if status == "completed" || status == "error" {
                        await MainActor.run {
                            self.isProcessing = false
                        }
                    }
                }
            }
            
        default:
            // Ignore other events for now
            break
        }
    }
    
    /// Extract text content from message parts
    private func extractText(from parts: [MessagePart]) -> String {
        parts
            .filter { $0.type == .text }
            .compactMap { $0.text }
            .joined(separator: "\n")
    }
}



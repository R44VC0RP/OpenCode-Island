//
//  StartupCoordinator.swift
//  OpenCodeIsland
//
//  Coordinates async initialization to ensure proper startup order.
//  Prevents race conditions between server startup and UI initialization.
//

import Combine
import Foundation

/// Phases of the startup sequence
enum StartupPhase: Equatable {
    case notStarted
    case startingServer
    case waitingForServer
    case connectingService
    case loadingSpeech
    case ready
    case failed(StartupError)
    
    var isTerminal: Bool {
        switch self {
        case .ready, .failed:
            return true
        default:
            return false
        }
    }
    
    var displayMessage: String {
        switch self {
        case .notStarted:
            return "Initializing..."
        case .startingServer:
            return "Starting OpenCode server..."
        case .waitingForServer:
            return "Waiting for server to be ready..."
        case .connectingService:
            return "Connecting to server..."
        case .loadingSpeech:
            return "Loading speech recognition..."
        case .ready:
            return "Ready"
        case .failed(let error):
            return error.userMessage
        }
    }
}

/// Errors that can occur during startup
enum StartupError: Error, Equatable {
    case serverFailedToStart(String)
    case serverHealthCheckFailed(String)
    case timeout
    case cancelled
    
    var userMessage: String {
        switch self {
        case .serverFailedToStart(let message):
            return "Failed to start server: \(message)"
        case .serverHealthCheckFailed(let message):
            return "Server not responding: \(message)"
        case .timeout:
            return "Startup timed out"
        case .cancelled:
            return "Startup cancelled"
        }
    }
    
    var isRetryable: Bool {
        switch self {
        case .cancelled:
            return false
        default:
            return true
        }
    }
}

/// Coordinates the async startup sequence to ensure proper initialization order
@MainActor
class StartupCoordinator: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var phase: StartupPhase = .notStarted
    @Published private(set) var progress: Double = 0.0
    
    // MARK: - Dependencies
    
    private let serverManager: OpenCodeServerManager
    private let speechService: SpeechService
    
    // MARK: - Configuration
    
    private let serverStartTimeout: TimeInterval = 30.0
    private let serverHealthCheckInterval: TimeInterval = 0.5
    private let maxHealthCheckAttempts = 20
    
    // MARK: - Internal State
    
    private var startupTask: Task<Bool, Never>?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Callbacks
    
    /// Called when startup completes successfully
    var onReady: (() -> Void)?
    
    /// Called when startup fails
    var onFailed: ((StartupError) -> Void)?
    
    // MARK: - Initialization
    
    init(
        serverManager: OpenCodeServerManager = .shared,
        speechService: SpeechService = .shared
    ) {
        self.serverManager = serverManager
        self.speechService = speechService
    }
    
    deinit {
        startupTask?.cancel()
    }
    
    // MARK: - Startup Sequence
    
    /// Perform the coordinated startup sequence
    /// - Returns: true if startup succeeded, false otherwise
    @discardableResult
    func performStartup() async -> Bool {
        // Cancel any existing startup
        startupTask?.cancel()
        
        // Reset state
        phase = .notStarted
        progress = 0.0
        
        // Create new startup task
        let task = Task<Bool, Never> { [weak self] in
            guard let self = self else { return false }
            
            do {
                // Phase 1: Start server
                await self.updatePhase(.startingServer, progress: 0.1)
                
                await self.serverManager.startServer()
                
                guard !Task.isCancelled else {
                    await self.updatePhase(.failed(.cancelled), progress: 0.0)
                    return false
                }
                
                // Phase 2: Wait for server to be healthy
                await self.updatePhase(.waitingForServer, progress: 0.3)
                
                guard self.serverManager.isRunning else {
                    let error = self.serverManager.errorMessage ?? "Unknown error"
                    await self.updatePhase(.failed(.serverFailedToStart(error)), progress: 0.0)
                    self.onFailed?(.serverFailedToStart(error))
                    return false
                }
                
                // Verify server is responding
                let isHealthy = await self.waitForServerHealth()
                
                guard !Task.isCancelled else {
                    await self.updatePhase(.failed(.cancelled), progress: 0.0)
                    return false
                }
                
                guard isHealthy else {
                    await self.updatePhase(.failed(.serverHealthCheckFailed("Server not responding")), progress: 0.0)
                    self.onFailed?(.serverHealthCheckFailed("Server not responding"))
                    return false
                }
                
                // Phase 3: Service connection is handled by NotchViewModel
                await self.updatePhase(.connectingService, progress: 0.6)
                
                // Small delay to ensure server is fully ready
                try? await Task.sleep(for: .milliseconds(200))
                
                guard !Task.isCancelled else {
                    await self.updatePhase(.failed(.cancelled), progress: 0.0)
                    return false
                }
                
                // Phase 4: Start loading speech model in background (non-blocking)
                await self.updatePhase(.loadingSpeech, progress: 0.8)
                
                // Fire and forget - speech loading can continue after startup
                Task.detached(priority: .background) { [speechService = self.speechService] in
                    await speechService.loadModel()
                }
                
                // Startup complete!
                await self.updatePhase(.ready, progress: 1.0)
                self.onReady?()
                return true
                
            } catch {
                if Task.isCancelled {
                    await self.updatePhase(.failed(.cancelled), progress: 0.0)
                } else {
                    let startupError = StartupError.serverFailedToStart(error.localizedDescription)
                    await self.updatePhase(.failed(startupError), progress: 0.0)
                    self.onFailed?(startupError)
                }
                return false
            }
        }
        
        startupTask = task
        return await task.value
    }
    
    /// Cancel the current startup sequence
    func cancelStartup() {
        startupTask?.cancel()
        startupTask = nil
    }
    
    /// Retry startup after a failure
    @discardableResult
    func retryStartup() async -> Bool {
        guard case .failed(let error) = phase, error.isRetryable else {
            return false
        }
        
        return await performStartup()
    }
    
    // MARK: - Private Helpers
    
    private func updatePhase(_ newPhase: StartupPhase, progress: Double) async {
        await MainActor.run {
            self.phase = newPhase
            self.progress = progress
        }
    }
    
    /// Wait for server health check to pass
    private func waitForServerHealth() async -> Bool {
        let port = serverManager.serverPort
        guard port > 0 else { return false }
        
        let client = OpenCodeClient(port: port, hostname: "127.0.0.1")
        
            for attempt in 0..<maxHealthCheckAttempts {
                if Task.isCancelled { return false }
                
                if await client.isServerRunning() {
                    return true
                }
                
                let checkProgress = 0.3 + (Double(attempt) / Double(maxHealthCheckAttempts)) * 0.2
                await updatePhase(.waitingForServer, progress: checkProgress)
                
                try? await Task.sleep(for: .milliseconds(Int(serverHealthCheckInterval * 1000)))
            }
        
        return false
    }
}

// MARK: - Startup Coordinator Singleton

extension StartupCoordinator {
    static let shared = StartupCoordinator()
}

//
//  OpenCodeServerManager.swift
//  ClaudeIsland
//
//  Manages the OpenCode server process lifecycle
//

import Combine
import Foundation

/// Manages starting, stopping, and monitoring the OpenCode server process
@MainActor
class OpenCodeServerManager: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = OpenCodeServerManager()
    
    // MARK: - Published State
    
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var serverPort: Int = 4096
    @Published private(set) var errorMessage: String?
    
    // MARK: - Private State
    
    private var serverProcess: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var isOwnedProcess: Bool = false  // Did we start this server?
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Server Lifecycle
    
    /// Start the OpenCode server if auto-start is enabled and no server is running
    func startServerIfNeeded() async {
        // Skip if auto-start is disabled
        guard AppSettings.autoStartServer else {
            print("[ServerManager] Auto-start disabled, skipping")
            return
        }
        
        // Skip if custom URL is set (user is connecting to external server)
        if let customURL = AppSettings.serverURL, !customURL.isEmpty {
            print("[ServerManager] Custom URL set (\(customURL)), skipping auto-start")
            return
        }
        
        // Check if a server is already running on the default port
        if await isServerAlreadyRunning() {
            print("[ServerManager] Server already running on port \(serverPort)")
            isRunning = true
            isOwnedProcess = false
            return
        }
        
        // Start our own server
        await startServer()
    }
    
    /// Start the OpenCode server process
    func startServer() async {
        guard serverProcess == nil else {
            print("[ServerManager] Server already started by us")
            return
        }
        
        // Find the opencode binary
        guard let opencodePath = findOpencodeBinary() else {
            errorMessage = "OpenCode not found. Please install it first."
            print("[ServerManager] OpenCode binary not found")
            return
        }
        
        // Get the working directory
        let workingDirectory = AppSettings.effectiveWorkingDirectory
        print("[ServerManager] Starting OpenCode server from: \(opencodePath)")
        print("[ServerManager] Working directory: \(workingDirectory)")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opencodePath)
        process.arguments = ["serve", "--port", "\(serverPort)"]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        
        // Set up pipes to capture output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Set environment to inherit user's shell environment
        var environment = ProcessInfo.processInfo.environment
        // Ensure PATH includes common locations
        if let path = environment["PATH"] {
            environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(path)"
        }
        process.environment = environment
        
        // Handle process termination
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleProcessTermination(exitCode: proc.terminationStatus)
            }
        }
        
        self.serverProcess = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        
        do {
            try process.run()
            isRunning = true
            isOwnedProcess = true
            errorMessage = nil
            print("[ServerManager] Server process started with PID: \(process.processIdentifier)")
            
            // Start reading output in background
            startReadingOutput()
            
            // Wait a moment for server to initialize
            try? await Task.sleep(for: .milliseconds(500))
            
        } catch {
            errorMessage = "Failed to start server: \(error.localizedDescription)"
            print("[ServerManager] Failed to start server: \(error)")
            serverProcess = nil
            isRunning = false
        }
    }
    
    /// Stop the OpenCode server process
    func stopServer() {
        guard let process = serverProcess, isOwnedProcess else {
            print("[ServerManager] No owned server process to stop")
            return
        }
        
        print("[ServerManager] Stopping server process...")
        
        // Send SIGTERM for graceful shutdown
        process.terminate()
        
        // Give it a moment to shut down gracefully
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if process.isRunning {
                print("[ServerManager] Server didn't stop gracefully, sending SIGKILL")
                process.interrupt()
            }
            
            Task { @MainActor in
                self?.serverProcess = nil
                self?.isRunning = false
                self?.isOwnedProcess = false
            }
        }
    }
    
    /// Restart the server (stop and start)
    func restartServer() async {
        stopServer()
        try? await Task.sleep(for: .seconds(1))
        await startServer()
    }
    
    // MARK: - Private Helpers
    
    /// Check if an OpenCode server is already running on the target port
    private func isServerAlreadyRunning() async -> Bool {
        guard let components = AppSettings.serverComponents else {
            return false
        }
        
        let client = OpenCodeClient(port: components.port, hostname: components.host)
        return await client.isServerRunning()
    }
    
    /// Find the opencode binary in common locations
    private func findOpencodeBinary() -> String? {
        let possiblePaths = [
            "/usr/local/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "\(NSHomeDirectory())/.local/bin/opencode",
            "\(NSHomeDirectory())/go/bin/opencode",
            "/usr/bin/opencode"
        ]
        
        // Also check PATH
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            let pathDirs = pathEnv.split(separator: ":").map(String.init)
            for dir in pathDirs {
                let fullPath = "\(dir)/opencode"
                if FileManager.default.isExecutableFile(atPath: fullPath) {
                    return fullPath
                }
            }
        }
        
        // Check specific paths
        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        
        // Try using `which` as fallback
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["opencode"]
        
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                return output
            }
        } catch {
            print("[ServerManager] which command failed: \(error)")
        }
        
        return nil
    }
    
    /// Start reading output from the server process
    private func startReadingOutput() {
        guard let outputPipe = outputPipe else { return }
        
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                print("[OpenCode Server] \(output)")
            }
        }
        
        errorPipe?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                print("[OpenCode Server ERROR] \(output)")
            }
        }
    }
    
    /// Handle server process termination
    private func handleProcessTermination(exitCode: Int32) {
        print("[ServerManager] Server process terminated with exit code: \(exitCode)")
        
        serverProcess = nil
        isRunning = false
        isOwnedProcess = false
        
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        
        if exitCode != 0 {
            errorMessage = "Server exited with code \(exitCode)"
        }
    }
}

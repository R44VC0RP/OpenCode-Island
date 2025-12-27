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
    @Published private(set) var serverPort: Int = 0
    @Published private(set) var workingDirectory: String = ""
    @Published private(set) var errorMessage: String?
    
    // MARK: - Private State
    
    private var serverProcess: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    
    // MARK: - Computed Properties
    
    /// The server URL for connecting
    var serverURL: String {
        "http://127.0.0.1:\(serverPort)"
    }
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Server Lifecycle
    
    /// Start the OpenCode server with the configured working directory
    func startServer() async {
        // Stop any existing server first
        if serverProcess != nil {
            stopServer()
            try? await Task.sleep(for: .milliseconds(500))
        }
        
        // Find the opencode binary
        guard let opencodePath = findOpencodeBinary() else {
            errorMessage = "OpenCode not found. Please install it first."
            print("[ServerManager] OpenCode binary not found")
            return
        }
        
        // Get a random available port
        let port = findAvailablePort()
        
        // Get the working directory
        let workingDir = AppSettings.effectiveWorkingDirectory
        
        print("[ServerManager] Starting OpenCode server from: \(opencodePath)")
        print("[ServerManager] Working directory: \(workingDir)")
        print("[ServerManager] Port: \(port)")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opencodePath)
        process.arguments = ["serve", "--port", "\(port)"]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        
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
            serverPort = port
            workingDirectory = workingDir
            isRunning = true
            errorMessage = nil
            print("[ServerManager] Server process started with PID: \(process.processIdentifier)")
            
            // Start reading output in background
            startReadingOutput()
            
            // Wait a moment for server to initialize
            try? await Task.sleep(for: .milliseconds(800))
            
        } catch {
            errorMessage = "Failed to start server: \(error.localizedDescription)"
            print("[ServerManager] Failed to start server: \(error)")
            serverProcess = nil
            isRunning = false
        }
    }
    
    /// Stop the OpenCode server process
    func stopServer() {
        guard let process = serverProcess else {
            print("[ServerManager] No server process to stop")
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
                self?.serverPort = 0
            }
        }
    }
    
    /// Restart the server with current settings
    func restartServer() async {
        stopServer()
        try? await Task.sleep(for: .seconds(1))
        await startServer()
    }
    
    /// Restart the server if the working directory has changed
    func restartIfDirectoryChanged() async {
        let expectedDir = AppSettings.effectiveWorkingDirectory
        if isRunning && workingDirectory != expectedDir {
            print("[ServerManager] Working directory changed from \(workingDirectory) to \(expectedDir), restarting...")
            await restartServer()
        }
    }
    
    // MARK: - Private Helpers
    
    /// Find an available port for the server
    private func findAvailablePort() -> Int {
        // Start from a random port in a high range to avoid conflicts
        let basePort = Int.random(in: 19000...19999)
        
        for offset in 0..<100 {
            let port = basePort + offset
            if isPortAvailable(port) {
                return port
            }
        }
        
        // Fallback to a random port if all in range are taken
        return Int.random(in: 20000...29999)
    }
    
    /// Check if a port is available
    private func isPortAvailable(_ port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        return bindResult == 0
    }
    
    /// Find the opencode binary in common locations
    private func findOpencodeBinary() -> String? {
        let possiblePaths = [
            "\(NSHomeDirectory())/.opencode/bin/opencode",  // Default install location
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
        serverPort = 0
        
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        
        if exitCode != 0 {
            errorMessage = "Server exited with code \(exitCode)"
        }
    }
}

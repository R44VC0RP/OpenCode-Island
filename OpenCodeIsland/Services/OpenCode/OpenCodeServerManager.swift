//
//  OpenCodeServerManager.swift
//  OpenCodeIsland
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
        process.terminationHandler = { proc in
            Task { @MainActor in
                OpenCodeServerManager.shared.handleProcessTermination(process: proc, exitCode: proc.terminationStatus)
            }
        }
        
        self.serverProcess = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        
        do {
            try process.run()
            serverPort = port
            workingDirectory = workingDir
            errorMessage = nil
            print("[ServerManager] Server process started with PID: \(process.processIdentifier)")
            
            // Start reading output in background
            startReadingOutput()
            
            // Wait for server to become healthy with retry loop
            let healthy = await waitForServerReady(port: port, timeout: 10.0)
            if healthy {
                isRunning = true
                print("[ServerManager] Server is healthy and ready")
            } else {
                print("[ServerManager] Server failed to become healthy within timeout")
                errorMessage = "Server started but failed to respond. Check if OpenCode is working correctly."
                stopServer()
                return
            }
            
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
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            if process.isRunning {
                print("[ServerManager] Server didn't stop gracefully, sending SIGKILL")
                process.interrupt()
            }
            
            Task { @MainActor in
                let manager = OpenCodeServerManager.shared
                guard manager.serverProcess === process else { return }
                manager.serverProcess = nil
                manager.isRunning = false
                manager.serverPort = 0
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
    
    /// Wait for the server to become ready by polling the health endpoint
    /// Runs off the main actor to avoid blocking UI during startup
    private func waitForServerReady(port: Int, timeout: TimeInterval) async -> Bool {
        // Capture process reference for the detached task
        let process = self.serverProcess
        
        // Run the polling loop off the main actor to avoid blocking UI
        let result = await Task.detached { [process] () -> Bool in
            let client = OpenCodeClient(port: port, hostname: "127.0.0.1")
            let startTime = Date()
            let pollInterval: UInt64 = 250_000_000 // 250ms in nanoseconds
            
            print("[ServerManager] Waiting for server to become ready (timeout: \(timeout)s)...")
            
            while Date().timeIntervalSince(startTime) < timeout {
                if await client.isServerRunning() {
                    return true
                }
                
                // Check if process died (use captured reference)
                if process == nil || !(process?.isRunning ?? false) {
                    print("[ServerManager] Server process died while waiting for ready state")
                    return false
                }
                
                try? await Task.sleep(nanoseconds: pollInterval)
            }
            
            print("[ServerManager] Timeout waiting for server to become ready")
            return false
        }.value
        
        return result
    }
    
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
        // Use FileManager for proper home directory (works correctly even in sandboxed apps)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        
        print("[ServerManager] Looking for opencode binary (home: \(home))")
        
        // Check all common installation paths
        let possiblePaths = [
            // OpenCode default (highest priority)
            "\(home)/.opencode/bin/opencode",
            // Homebrew (system-wide, always accessible)
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            // Generic local
            "\(home)/.local/bin/opencode",
            // Bun
            "\(home)/.bun/bin/opencode",
            // npm/pnpm global
            "\(home)/.npm-global/bin/opencode",
            "\(home)/.pnpm-global/bin/opencode",
            "\(home)/.local/share/pnpm/opencode",
            // Node version managers
            "\(home)/.nvm/versions/node/*/bin/opencode",  // Will be checked via glob-like expansion below
            "\(home)/.n/bin/opencode",
            "\(home)/.volta/bin/opencode",
            "\(home)/.fnm/aliases/default/bin/opencode",
            // Go
            "\(home)/go/bin/opencode",
            // Cargo/Rust
            "\(home)/.cargo/bin/opencode",
            // System
            "/usr/bin/opencode"
        ]
        
        // Check specific paths first (fast)
        for path in possiblePaths {
            // Handle wildcard paths (like nvm)
            if path.contains("*") {
                if let expandedPath = expandWildcardPath(path) {
                    return expandedPath
                }
            } else if FileManager.default.isExecutableFile(atPath: path) {
                print("[ServerManager] Found opencode at: \(path)")
                return path
            }
        }
        
        // Build an augmented PATH for discovery (GUI apps have limited PATH)
        // Note: 'home' is already defined at the top of this function
        var pathDirs: [String] = [
            // Common install locations that may not be in GUI app PATH
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.opencode/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
        ]
        
        // Add existing PATH entries
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            pathDirs.append(contentsOf: pathEnv.split(separator: ":").map(String.init))
        }
        
        // Deduplicate while preserving order
        var seenDirs = Set<String>()
        for dir in pathDirs {
            guard !seenDirs.contains(dir) else { continue }
            seenDirs.insert(dir)
            
            let fullPath = "\(dir)/opencode"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                print("[ServerManager] Found opencode in augmented PATH at: \(fullPath)")
                return fullPath
            }
        }
        
        // Try using shell to get full user PATH (handles .bashrc, .zshrc, etc.)
        if let shellPath = findViaShell() {
            return shellPath
        }
        
        return nil
    }
    
    /// Expand a path containing wildcards (e.g., for nvm)
    private func expandWildcardPath(_ pattern: String) -> String? {
        let components = pattern.split(separator: "/", omittingEmptySubsequences: false)
        var currentPath = ""
        
        for component in components {
            if component.isEmpty {
                currentPath = "/"
                continue
            }
            
            if component.contains("*") {
                // Expand this directory
                let searchPath = currentPath.isEmpty ? "/" : currentPath
                guard let contents = try? FileManager.default.contentsOfDirectory(atPath: searchPath) else {
                    return nil
                }
                
                // Find matching directories
                let pattern = String(component)
                for item in contents {
                    if matchesWildcard(item, pattern: pattern) {
                        let expandedPath = "\(searchPath)/\(item)"
                        // Continue with rest of path
                        let remaining = components.dropFirst(components.firstIndex(of: component)! + 1)
                        if remaining.isEmpty {
                            if FileManager.default.isExecutableFile(atPath: expandedPath) {
                                return expandedPath
                            }
                        } else {
                            let restPattern = remaining.joined(separator: "/")
                            if let result = expandWildcardPath("\(expandedPath)/\(restPattern)") {
                                return result
                            }
                        }
                    }
                }
                return nil
            } else {
                currentPath = currentPath.isEmpty ? "/\(component)" : "\(currentPath)/\(component)"
            }
        }
        
        if FileManager.default.isExecutableFile(atPath: currentPath) {
            return currentPath
        }
        return nil
    }
    
    /// Simple wildcard matching (only supports * for now)
    private func matchesWildcard(_ string: String, pattern: String) -> Bool {
        if pattern == "*" { return true }
        if !pattern.contains("*") { return string == pattern }
        
        // Simple prefix/suffix matching
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
        if parts.count == 2 {
            let prefix = String(parts[0])
            let suffix = String(parts[1])
            return string.hasPrefix(prefix) && string.hasSuffix(suffix)
        }
        return false
    }
    
    /// Try to find opencode using the user's shell environment
    private func findViaShell() -> String? {
        // Determine the user's login shell
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Use -l for login shell (loads .zshrc/.bashrc), -c to run command
        process.arguments = ["-l", "-c", "which opencode"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty,
               FileManager.default.isExecutableFile(atPath: output) {
                print("[ServerManager] Found opencode via shell at: \(output)")
                return output
            }
        } catch {
            print("[ServerManager] Shell lookup failed: \(error)")
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
    private func handleProcessTermination(process: Process, exitCode: Int32) {
        print("[ServerManager] Server process terminated with exit code: \(exitCode)")
        
        guard serverProcess === process else { return }
        
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

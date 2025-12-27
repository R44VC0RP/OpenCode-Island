//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation

enum AppSettings {
    static let defaults = UserDefaults.standard
    
    // MARK: - Constants
    
    /// Default OpenCode server URL
    static let defaultServerURL = "http://127.0.0.1:4096"

    // MARK: - Keys

    private enum Keys {
        static let summonHotkey = "summonHotkey"
        static let selectedScreen = "selectedScreen"
        static let persistedSessionID = "persistedSessionID"
        static let defaultAgentID = "defaultAgentID"
        static let defaultModelID = "defaultModelID"  // Format: "providerID/modelID"
        static let serverURL = "serverURL"
        static let autoStartServer = "autoStartServer"
        static let workingDirectory = "workingDirectory"
    }

    // MARK: - Hotkey Settings
    
    /// The hotkey configuration for summoning the island
    /// Stored as encoded HotkeyType data
    static var summonHotkeyData: Data? {
        get { defaults.data(forKey: Keys.summonHotkey) }
        set { defaults.set(newValue, forKey: Keys.summonHotkey) }
    }
    
    // MARK: - OpenCode Settings
    
    /// Persisted session ID for conversation continuity
    static var persistedSessionID: String? {
        get { defaults.string(forKey: Keys.persistedSessionID) }
        set { defaults.set(newValue, forKey: Keys.persistedSessionID) }
    }
    
    /// User's preferred default agent ID
    static var defaultAgentID: String? {
        get { defaults.string(forKey: Keys.defaultAgentID) }
        set { defaults.set(newValue, forKey: Keys.defaultAgentID) }
    }
    
    /// User's preferred default model ID (format: "providerID/modelID")
    static var defaultModelID: String? {
        get { defaults.string(forKey: Keys.defaultModelID) }
        set { defaults.set(newValue, forKey: Keys.defaultModelID) }
    }
    
    /// Custom server URL override (nil uses default 4096)
    static var serverURL: String? {
        get { defaults.string(forKey: Keys.serverURL) }
        set { defaults.set(newValue, forKey: Keys.serverURL) }
    }
    
    /// Whether to auto-start the OpenCode server (defaults to true)
    static var autoStartServer: Bool {
        get {
            // Default to true if not set
            if defaults.object(forKey: Keys.autoStartServer) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.autoStartServer)
        }
        set { defaults.set(newValue, forKey: Keys.autoStartServer) }
    }
    
    /// Custom working directory override (nil uses home directory)
    static var workingDirectory: String? {
        get { defaults.string(forKey: Keys.workingDirectory) }
        set { defaults.set(newValue, forKey: Keys.workingDirectory) }
    }
    
    /// Get the effective working directory (custom or home directory)
    static var effectiveWorkingDirectory: String {
        if let custom = workingDirectory, !custom.isEmpty {
            return custom
        }
        return NSHomeDirectory()
    }
    
    /// Get the effective server URL (custom or default)
    static var effectiveServerURL: String {
        if let custom = serverURL, !custom.isEmpty {
            return custom
        }
        return defaultServerURL
    }
    
    /// Parse the server URL into host and port components
    static var serverComponents: (host: String, port: Int)? {
        guard let url = URL(string: effectiveServerURL),
              let host = url.host else {
            return nil
        }
        let port = url.port ?? 4096
        return (host, port)
    }
}

//
//  OpenCodeError.swift
//  ClaudeIsland
//
//  Error types for OpenCode server communication
//

import Foundation

/// Errors that can occur when communicating with the OpenCode server
enum OpenCodeError: LocalizedError {
    /// Server is not running or unreachable
    case serverNotRunning
    
    /// Server returned an HTTP error
    case httpError(statusCode: Int, message: String?)
    
    /// Failed to decode response from server
    case decodingError(Error)
    
    /// Failed to encode request
    case encodingError(Error)
    
    /// Network error occurred
    case networkError(Error)
    
    /// No active session exists
    case noActiveSession
    
    /// Session was not found
    case sessionNotFound(String)
    
    /// Agent was not found
    case agentNotFound(String)
    
    /// Request was cancelled
    case cancelled
    
    /// Request timed out
    case timeout
    
    /// Invalid URL
    case invalidURL(String)
    
    /// SSE stream error
    case streamError(String)
    
    /// Unknown error
    case unknown(String)
    
    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return "OpenCode server is not running. Start it with 'opencode serve' or run the OpenCode TUI."
            
        case .httpError(let statusCode, let message):
            if let message = message {
                return "Server error (\(statusCode)): \(message)"
            }
            return "Server error (HTTP \(statusCode))"
            
        case .decodingError(let error):
            return "Failed to parse server response: \(error.localizedDescription)"
            
        case .encodingError(let error):
            return "Failed to encode request: \(error.localizedDescription)"
            
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
            
        case .noActiveSession:
            return "No active session. Please start a new conversation."
            
        case .sessionNotFound(let id):
            return "Session '\(id)' not found."
            
        case .agentNotFound(let id):
            return "Agent '\(id)' not found."
            
        case .cancelled:
            return "Request was cancelled."
            
        case .timeout:
            return "Request timed out."
            
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
            
        case .streamError(let message):
            return "Stream error: \(message)"
            
        case .unknown(let message):
            return message
        }
    }
    
    /// User-friendly short message
    var shortDescription: String {
        switch self {
        case .serverNotRunning:
            return "Server not running"
        case .httpError(let statusCode, _):
            return "Server error (\(statusCode))"
        case .decodingError:
            return "Invalid response"
        case .encodingError:
            return "Request error"
        case .networkError:
            return "Network error"
        case .noActiveSession:
            return "No active session"
        case .sessionNotFound:
            return "Session not found"
        case .agentNotFound:
            return "Agent not found"
        case .cancelled:
            return "Cancelled"
        case .timeout:
            return "Timed out"
        case .invalidURL:
            return "Invalid URL"
        case .streamError:
            return "Stream error"
        case .unknown:
            return "Unknown error"
        }
    }
    
    /// Whether this error is likely transient and retrying might help
    var isRetryable: Bool {
        switch self {
        case .serverNotRunning, .networkError, .timeout:
            return true
        case .httpError(let statusCode, _):
            return statusCode >= 500
        default:
            return false
        }
    }
}

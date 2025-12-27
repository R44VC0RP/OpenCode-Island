//
//  OpenCodeModels.swift
//  ClaudeIsland
//
//  Codable types for OpenCode server API responses
//

import Foundation

// MARK: - Health Check

struct HealthResponse: Codable {
    let healthy: Bool
    let version: String
}

// MARK: - Agents

struct ServerAgent: Codable, Identifiable, Equatable {
    let name: String
    let mode: AgentMode
    let native: Bool?
    let isDefault: Bool?
    
    /// Computed id for Identifiable conformance (uses name)
    var id: String { name }
    
    enum AgentMode: String, Codable {
        case primary
        case subagent
        case all
    }
    
    enum CodingKeys: String, CodingKey {
        case name
        case mode
        case native
        case isDefault = "default"
    }
    
    /// Whether this agent can be directly selected by users
    var isPrimary: Bool {
        mode == .primary || mode == .all
    }
}

// MARK: - Sessions

struct Session: Codable, Identifiable {
    let id: String
    let title: String?
    let version: String?
    let projectID: String?
    let directory: String?
    let time: SessionTime?
    let parentID: String?
    let share: ShareInfo?
    
    struct SessionTime: Codable {
        let created: Int64  // Unix timestamp in milliseconds
        let updated: Int64
        
        var createdDate: Date {
            Date(timeIntervalSince1970: Double(created) / 1000.0)
        }
        
        var updatedDate: Date {
            Date(timeIntervalSince1970: Double(updated) / 1000.0)
        }
    }
    
    struct ShareInfo: Codable {
        let url: String?
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case version
        case projectID
        case directory
        case time
        case parentID = "parent_id"
        case share
    }
    
    /// Convenience accessor for created date
    var createdAt: Date {
        time?.createdDate ?? Date()
    }
}

struct CreateSessionRequest: Codable {
    let title: String?
    let parentID: String?
    
    // Server uses camelCase, no CodingKeys needed
    
    init(title: String? = nil, parentID: String? = nil) {
        self.title = title
        self.parentID = parentID
    }
}

// MARK: - Messages

struct MessagePart: Codable {
    let type: PartType
    let text: String?
    let toolInvocationID: String?
    let toolName: String?
    let state: String?
    let id: String?
    
    enum PartType: String, Codable {
        case text
        case toolInvocation = "tool-invocation"
        case toolResult = "tool-result"
        case stepStart = "step-start"
        case unknown
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            self = PartType(rawValue: rawValue) ?? .unknown
        }
    }
    
    // No CodingKeys needed - server uses camelCase which Swift handles by default
}

struct MessageTime: Codable {
    let created: Int64
    let completed: Int64?
    
    var createdDate: Date {
        Date(timeIntervalSince1970: Double(created) / 1000.0)
    }
    
    var completedDate: Date? {
        guard let completed = completed else { return nil }
        return Date(timeIntervalSince1970: Double(completed) / 1000.0)
    }
}

struct MessagePath: Codable {
    let cwd: String?
    let root: String?
}

struct MessageTokens: Codable {
    let input: Int?
    let output: Int?
    let reasoning: Int?
    let cache: TokenCache?
    
    struct TokenCache: Codable {
        let read: Int?
        let write: Int?
    }
}

struct Message: Codable, Identifiable {
    let id: String
    let sessionID: String
    let role: MessageRole
    let time: MessageTime?
    let parentID: String?
    let modelID: String?
    let providerID: String?
    let mode: String?
    let agent: String?
    let path: MessagePath?
    let cost: Double?
    let tokens: MessageTokens?
    let finish: String?
    
    enum MessageRole: String, Codable {
        case user
        case assistant
    }
    
    /// Convenience accessor for created date
    var createdAt: Date {
        time?.createdDate ?? Date()
    }
    
    // No CodingKeys needed - server uses camelCase which Swift handles
}

struct MessageWithParts: Codable {
    let info: Message
    let parts: [MessagePart]
}

// MARK: - Prompt Request/Response

struct PromptRequest: Codable {
    let parts: [PromptPart]
    let agent: String?
    let model: ModelRef?
    let noReply: Bool?
    
    struct ModelRef: Codable {
        let providerID: String
        let modelID: String
    }
    
    init(text: String, agent: String? = nil) {
        self.parts = [PromptPart.text(text)]
        self.agent = agent
        self.model = nil
        self.noReply = nil
    }
    
    init(parts: [PromptPart], agent: String? = nil) {
        self.parts = parts
        self.agent = agent
        self.model = nil
        self.noReply = nil
    }
}

/// A part of a prompt - can be text or an image
enum PromptPart: Codable {
    case text(String)
    case image(data: String, mediaType: String)  // base64 data
    
    enum CodingKeys: String, CodingKey {
        case type
        case text
        case image
        case mediaType
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mediaType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .image)
            try container.encode(mediaType, forKey: .mediaType)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image":
            let data = try container.decode(String.self, forKey: .image)
            let mediaType = try container.decode(String.self, forKey: .mediaType)
            self = .image(data: data, mediaType: mediaType)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown part type: \(type)")
            )
        }
    }
}

// MARK: - Path

/// Response from GET /path - server's current working directory
struct PathInfo: Codable {
    let cwd: String
    let root: String?
}

// MARK: - Config

struct ServerConfig: Codable {
    let model: String?
    let defaultAgent: String?
    // Server likely uses camelCase, no CodingKeys needed
}

// MARK: - Providers & Models

/// Response from GET /provider
struct ProviderListResponse: Codable {
    let all: [Provider]
    let `default`: [String: String]  // providerID -> modelID
    let connected: [String]
}

struct Provider: Codable, Identifiable {
    let id: String
    let name: String
    let models: [String: ProviderModel]  // Dictionary keyed by model ID
    
    /// Get models as an array for easier iteration
    var modelsArray: [ProviderModel] {
        Array(models.values)
    }
}

struct ProviderModel: Codable, Identifiable {
    let id: String
    let name: String
    let providerID: String?
    let family: String?
    let status: String?
    let limit: ModelLimit?
    
    struct ModelLimit: Codable {
        let context: Int?
        let output: Int?
    }
}

/// A model reference with provider info for UI display
struct ModelRef: Identifiable, Equatable, Hashable {
    let providerID: String
    let modelID: String
    let displayName: String
    
    var id: String { "\(providerID)/\(modelID)" }
    
    init(providerID: String, modelID: String, displayName: String) {
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
    }
    
    init(provider: Provider, model: ProviderModel) {
        self.providerID = provider.id
        self.modelID = model.id
        self.displayName = "\(provider.name) - \(model.name)"
    }
}

// MARK: - SSE Events

/// Represents a Server-Sent Event from the OpenCode server
struct SSEEvent {
    let type: String
    let data: Data
    
    /// Decode the event data as a specific type
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

/// Event types sent by the server
enum OpenCodeEventType: String {
    case serverConnected = "server.connected"
    case sessionCreated = "session.created"
    case sessionUpdated = "session.updated"
    case messageCreated = "message.created"
    case messageUpdated = "message.updated"
    case partUpdated = "part.updated"
    case sessionStatus = "session.status"
    case unknown
    
    init(rawValue: String) {
        switch rawValue {
        case "server.connected": self = .serverConnected
        case "session.created": self = .sessionCreated
        case "session.updated": self = .sessionUpdated
        case "message.created": self = .messageCreated
        case "message.updated": self = .messageUpdated
        case "part.updated": self = .partUpdated
        case "session.status": self = .sessionStatus
        default: self = .unknown
        }
    }
}

/// Event payload for message part updates (streaming text)
struct PartUpdatedEvent: Codable {
    let properties: PartProperties
    
    struct PartProperties: Codable {
        let sessionID: String
        let messageID: String
        let part: MessagePart
        // Server uses camelCase, no CodingKeys needed
    }
}

/// Event payload for session status updates
struct SessionStatusEvent: Codable {
    let properties: StatusProperties
    
    struct StatusProperties: Codable {
        let sessionID: String
        let status: String  // "pending", "running", "completed", etc.
        // Server uses camelCase, no CodingKeys needed
    }
}

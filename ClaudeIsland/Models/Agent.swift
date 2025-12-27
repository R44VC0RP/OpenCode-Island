//
//  Agent.swift
//  ClaudeIsland
//
//  Model representing an OpenCode agent
//

import Foundation

struct Agent: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let name: String
    let description: String
    let icon: String  // SF Symbol name
    let mode: AgentMode
    
    enum AgentMode: String, Codable {
        case primary
        case subagent
        case all
    }
    
    // MARK: - Initialization
    
    init(id: String, name: String, description: String, icon: String, mode: AgentMode = .primary) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.mode = mode
    }
    
    /// Initialize from a ServerAgent
    init(from serverAgent: ServerAgent) {
        self.id = serverAgent.id
        // Capitalize the agent name to make a display name
        self.name = serverAgent.name.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        // Generate a description based on agent name since server doesn't provide one
        self.description = Agent.descriptionFor(agentID: serverAgent.id)
        self.icon = Agent.iconFor(agentID: serverAgent.id, mode: serverAgent.mode)
        self.mode = AgentMode(rawValue: serverAgent.mode.rawValue) ?? .primary
    }
    
    // MARK: - Description Mapping
    
    /// Get a description for known agents
    private static func descriptionFor(agentID: String) -> String {
        switch agentID.lowercased() {
        case "build":
            return "Default agent with all tools enabled"
        case "plan":
            return "Planning and analysis without making changes"
        case "general":
            return "General purpose assistant"
        case "explore":
            return "Explore and search codebases"
        case "review", "code-reviewer":
            return "Code review and analysis"
        case "docs", "documentation":
            return "Documentation and explanations"
        case "debug":
            return "Debug issues and errors"
        case "security":
            return "Security analysis"
        case "test":
            return "Testing and test generation"
        default:
            return "OpenCode agent"
        }
    }
    
    // MARK: - Icon Mapping
    
    /// Get an appropriate SF Symbol icon for an agent
    private static func iconFor(agentID: String, mode: ServerAgent.AgentMode) -> String {
        // Known agent icons
        switch agentID.lowercased() {
        case "build":
            return "hammer.fill"
        case "plan":
            return "list.bullet.clipboard"
        case "general":
            return "sparkles"
        case "explore":
            return "magnifyingglass"
        case "review", "code-reviewer":
            return "eye"
        case "docs", "documentation":
            return "book"
        case "debug":
            return "ladybug"
        case "security":
            return "lock.shield"
        case "test":
            return "checkmark.circle"
        default:
            // Default icon based on mode
            return mode == .subagent ? "person.crop.circle" : "cpu"
        }
    }
    
    // MARK: - Fallback Agents
    
    /// Fallback agents when server is not available
    static let fallback: [Agent] = [
        Agent(
            id: "build",
            name: "Build",
            description: "Default agent with all tools enabled",
            icon: "hammer.fill",
            mode: .primary
        ),
        Agent(
            id: "plan",
            name: "Plan",
            description: "Planning and analysis without making changes",
            icon: "list.bullet.clipboard",
            mode: .primary
        )
    ]
}

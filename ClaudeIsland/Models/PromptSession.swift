//
//  PromptSession.swift
//  ClaudeIsland
//
//  Represents a single prompt/response session
//

import Foundation

struct PromptSession: Identifiable, Equatable {
    let id: UUID
    let prompt: String
    let agent: Agent?
    let startedAt: Date
    var result: String?
    var completedAt: Date?
    
    var isComplete: Bool {
        result != nil
    }
    
    var duration: TimeInterval? {
        guard let completedAt = completedAt else { return nil }
        return completedAt.timeIntervalSince(startedAt)
    }
    
    init(prompt: String, agent: Agent? = nil) {
        self.id = UUID()
        self.prompt = prompt
        self.agent = agent
        self.startedAt = Date()
        self.result = nil
        self.completedAt = nil
    }
}

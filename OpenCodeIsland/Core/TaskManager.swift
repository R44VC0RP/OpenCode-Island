//
//  TaskManager.swift
//  OpenCodeIsland
//
//  Manages async task lifecycle with proper cancellation guarantees.
//

import Foundation

@MainActor
final class TaskManager {
    
    private struct ManagedTask {
        let task: Task<Void, Never>
        let name: String
        let startTime: Date
    }
    
    private var activeTasks: [String: ManagedTask] = [:]
    
    static let shared = TaskManager()
    
    private init() {}
    
    func start(
        id: String,
        priority: TaskPriority = .userInitiated,
        operation: @escaping @Sendable () async -> Void
    ) {
        cancel(id: id)
        
        let task = Task(priority: priority) { [weak self] in
            await operation()
            await self?.removeTask(id: id)
        }
        
        activeTasks[id] = ManagedTask(task: task, name: id, startTime: Date())
    }
    
    func cancel(id: String) {
        guard let managed = activeTasks.removeValue(forKey: id) else { return }
        managed.task.cancel()
    }
    
    func cancelAndWait(id: String, timeout: TimeInterval = 5.0) async {
        guard let managed = activeTasks.removeValue(forKey: id) else { return }
        managed.task.cancel()
        
        _ = await withTaskGroup(of: Void.self) { group in
            group.addTask { await managed.task.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
            }
            await group.next()
            group.cancelAll()
        }
    }
    
    func cancelAll() {
        for (_, managed) in activeTasks {
            managed.task.cancel()
        }
        activeTasks.removeAll()
    }
    
    func isRunning(id: String) -> Bool {
        guard let managed = activeTasks[id] else { return false }
        return !managed.task.isCancelled
    }
    
    private func removeTask(id: String) {
        activeTasks.removeValue(forKey: id)
    }
}

extension TaskManager {
    enum TaskID {
        static let promptSubmission = "prompt.submission"
        static let serverConnection = "server.connection"
        static let eventStream = "event.stream"
        static let dictation = "dictation"
        static let speechLoading = "speech.loading"
    }
}

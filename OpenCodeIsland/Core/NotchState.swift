//
//  NotchState.swift
//  OpenCodeIsland
//
//  Explicit state machine types for NotchViewModel.
//  Replaces 20+ implicit @Published properties with clear, validated states.
//

import AppKit
import Combine
import Foundation

// MARK: - Primary UI State

enum NotchUIState: Equatable {
    case closed
    case hovering
    case opened(content: NotchContentState)
    /// Closed but processing continues in background (compact indicator visible)
    case closedProcessing(ProcessingState)
    
    var isOpen: Bool {
        if case .opened = self { return true }
        return false
    }
    
    var isClosed: Bool {
        switch self {
        case .closed, .hovering, .closedProcessing:
            return true
        case .opened:
            return false
        }
    }
    
    var isProcessingInBackground: Bool {
        if case .closedProcessing = self { return true }
        return false
    }
}

// MARK: - Content States

enum NotchContentState: Equatable {
    case prompt(PromptState)
    case processing(ProcessingState)
    case result(ResultState)
    case menu
    case dictating(DictationState)
    
    var isPrompt: Bool {
        if case .prompt = self { return true }
        return false
    }
    
    var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }
    
    var isResult: Bool {
        if case .result = self { return true }
        return false
    }
    
    var isMenu: Bool {
        self == .menu
    }
    
    var isDictating: Bool {
        if case .dictating = self { return true }
        return false
    }
    
    var showsCompactWhenClosed: Bool {
        if case .processing = self { return true }
        return false
    }
}

// MARK: - Prompt State

struct PromptState: Equatable {
    var text: String = ""
    var selectedAgentID: String?
    var showAgentPicker: Bool = false
    var attachedImages: [AttachedImageRef] = []
    var errorMessage: String?
    
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachedImages.isEmpty
    }
    
    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    mutating func clearError() {
        errorMessage = nil
    }
    
    mutating func clearAll() {
        text = ""
        attachedImages = []
        errorMessage = nil
        showAgentPicker = false
    }
}

struct AttachedImageRef: Equatable, Identifiable {
    let id: UUID
    let mediaType: String
    let dataSize: Int
    
    static func == (lhs: AttachedImageRef, rhs: AttachedImageRef) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Processing State

struct ProcessingState: Equatable {
    let sessionID: String
    let startTime: Date
    var streamingText: String = ""
    var canCancel: Bool = true
    
    var elapsedTime: TimeInterval {
        Date().timeIntervalSince(startTime)
    }
}

// MARK: - Result State

struct ResultState: Equatable {
    let sessionID: String
    var streamingText: String
    var isExpanded: Bool = false
    var followUpText: String = ""
    
    mutating func toggleExpanded() {
        isExpanded.toggle()
    }
}

// MARK: - Dictation State

struct DictationState: Equatable {
    enum Phase: Equatable {
        case recording
        case transcribing
    }
    
    var phase: Phase
    var audioLevel: Float = 0.0
    var previousPromptState: PromptState
    
    var isRecording: Bool { phase == .recording }
    var isTranscribing: Bool { phase == .transcribing }
}

// MARK: - Retry State

struct PendingRetryState: Equatable {
    let parts: [PromptPartRef]
    let agentID: String?
    let errorMessage: String
    var attemptCount: Int = 0
    
    static let maxAttempts = 3
    
    var canRetry: Bool { attemptCount < Self.maxAttempts }
    
    mutating func incrementAttempt() {
        attemptCount += 1
    }
}

struct PromptPartRef: Equatable {
    enum PartType: Equatable {
        case text(String)
        case image(base64: String, mediaType: String)
    }
    let type: PartType
}

// MARK: - State Transitions

enum NotchStateTransition {
    case hover
    case unhover
    case open(reason: NotchOpenReason)
    case close
    case dismiss
    
    case updatePromptText(String)
    case selectAgent(String?)
    case toggleAgentPicker
    case attachImage(AttachedImageRef)
    case removeImage(UUID)
    case clearImages
    case setError(String)
    case clearError
    
    case startProcessing(sessionID: String)
    case updateStreamingText(String)
    case completeProcessing(resultText: String)
    case cancelProcessing
    case failProcessing(error: String, canRetry: Bool)
    
    case showResult(sessionID: String, text: String)
    case toggleResultExpanded
    case updateFollowUpText(String)
    
    case showMenu
    case hideMenu
    
    case startDictation(previousPrompt: PromptState)
    case updateAudioLevel(Float)
    case startTranscribing
    case completeDictation(transcription: String?)
    case cancelDictation
    
    case setPendingRetry(PendingRetryState)
    case clearPendingRetry
    case executePendingRetry
}

enum NotchOpenReason: Equatable {
    case click
    case hover
    case hotkey
    case notification
    case boot
    case unknown
}

// MARK: - State Machine

@MainActor
class NotchStateMachine: ObservableObject {
    
    @Published private(set) var uiState: NotchUIState = .closed
    @Published private(set) var pendingRetry: PendingRetryState?
    
    private var promptStateCache: PromptState = PromptState()
    
    var isOpen: Bool { uiState.isOpen }
    var isClosed: Bool { uiState.isClosed }
    
    var currentPromptState: PromptState? {
        guard case .opened(let content) = uiState,
              case .prompt(let state) = content else { return nil }
        return state
    }
    
    var currentProcessingState: ProcessingState? {
        if case .opened(let content) = uiState,
           case .processing(let state) = content {
            return state
        }
        if case .closedProcessing(let state) = uiState {
            return state
        }
        return nil
    }
    
    var backgroundProcessingState: ProcessingState? {
        guard case .closedProcessing(let state) = uiState else { return nil }
        return state
    }
    
    var currentResultState: ResultState? {
        guard case .opened(let content) = uiState,
              case .result(let state) = content else { return nil }
        return state
    }
    
    var currentDictationState: DictationState? {
        guard case .opened(let content) = uiState,
              case .dictating(let state) = content else { return nil }
        return state
    }
    
    var hasPendingRetry: Bool {
        pendingRetry?.canRetry ?? false
    }
    
    var contentType: NotchContentState? {
        switch uiState {
        case .opened(let content):
            return content
        case .closedProcessing(let processingState):
            return .processing(processingState)
        case .closed, .hovering:
            return nil
        }
    }
    
    func apply(_ transition: NotchStateTransition) -> Bool {
        guard isTransitionValid(transition) else {
            logInvalidTransition(transition)
            return false
        }
        
        performTransition(transition)
        return true
    }
    
    private func isTransitionValid(_ transition: NotchStateTransition) -> Bool {
        switch transition {
        case .hover:
            return uiState == .closed
        case .unhover:
            return uiState == .hovering
        case .open:
            return uiState.isClosed
        case .close:
            return uiState.isOpen
        case .dismiss:
            return true
            
        case .updatePromptText, .selectAgent, .toggleAgentPicker,
             .attachImage, .removeImage, .clearImages, .setError, .clearError:
            if case .opened(.prompt) = uiState { return true }
            return false
            
        case .startProcessing:
            if case .opened(.prompt) = uiState { return true }
            return false
        case .updateStreamingText:
            if case .opened(.processing) = uiState { return true }
            if case .closedProcessing = uiState { return true }
            return false
        case .cancelProcessing:
            if case .opened(.processing) = uiState { return true }
            if case .closedProcessing = uiState { return true }
            return false
        case .completeProcessing, .failProcessing:
            if case .opened(.processing) = uiState { return true }
            if case .closedProcessing = uiState { return true }
            return false
            
        case .showResult:
            if case .opened(.processing) = uiState { return true }
            if case .closedProcessing = uiState { return true }
            if case .opened(.prompt) = uiState { return true }
            return false
        case .toggleResultExpanded, .updateFollowUpText:
            if case .opened(.result) = uiState { return true }
            return false
            
        case .showMenu:
            if case .opened = uiState { return true }
            return false
        case .hideMenu:
            if case .opened(.menu) = uiState { return true }
            return false
            
        case .startDictation:
            if case .opened(.prompt) = uiState { return true }
            return false
        case .updateAudioLevel, .startTranscribing, .completeDictation, .cancelDictation:
            if case .opened(.dictating) = uiState { return true }
            return false
            
        case .setPendingRetry, .clearPendingRetry:
            return true
        case .executePendingRetry:
            return pendingRetry?.canRetry ?? false
        }
    }
    
    private func performTransition(_ transition: NotchStateTransition) {
        switch transition {
        case .hover:
            uiState = .hovering
            
        case .unhover:
            uiState = .closed
            
        case .open(let reason):
            if hasPendingRetry && (reason == .hotkey || reason == .click) {
                var promptState = promptStateCache
                if let retry = pendingRetry {
                    promptState.errorMessage = retry.errorMessage
                }
                pendingRetry = nil
                uiState = .opened(content: .prompt(promptState))
                return
            }
            if case .closedProcessing(let processingState) = uiState {
                uiState = .opened(content: .processing(processingState))
                return
            }
            let promptState = promptStateCache
            uiState = .opened(content: .prompt(promptState))
            
        case .close:
            if case .opened(let content) = uiState {
                switch content {
                case .prompt(let state):
                    promptStateCache = state
                    uiState = .closed
                case .processing(let processingState):
                    uiState = .closedProcessing(processingState)
                case .result, .menu, .dictating:
                    uiState = .closed
                }
            } else {
                uiState = .closed
            }
            
        case .dismiss:
            promptStateCache = PromptState()
            pendingRetry = nil
            uiState = .closed
            
        case .updatePromptText(let text):
            if case .opened(.prompt(var state)) = uiState {
                state.text = text
                uiState = .opened(content: .prompt(state))
            }
            
        case .selectAgent(let agentID):
            if case .opened(.prompt(var state)) = uiState {
                state.selectedAgentID = agentID
                state.showAgentPicker = false
                uiState = .opened(content: .prompt(state))
            }
            
        case .toggleAgentPicker:
            if case .opened(.prompt(var state)) = uiState {
                state.showAgentPicker.toggle()
                uiState = .opened(content: .prompt(state))
            }
            
        case .attachImage(let imageRef):
            if case .opened(.prompt(var state)) = uiState {
                state.attachedImages.append(imageRef)
                uiState = .opened(content: .prompt(state))
            }
            
        case .removeImage(let id):
            if case .opened(.prompt(var state)) = uiState {
                state.attachedImages.removeAll { $0.id == id }
                uiState = .opened(content: .prompt(state))
            }
            
        case .clearImages:
            if case .opened(.prompt(var state)) = uiState {
                state.attachedImages.removeAll()
                uiState = .opened(content: .prompt(state))
            }
            
        case .setError(let message):
            if case .opened(.prompt(var state)) = uiState {
                state.errorMessage = message
                uiState = .opened(content: .prompt(state))
            }
            
        case .clearError:
            if case .opened(.prompt(var state)) = uiState {
                state.errorMessage = nil
                uiState = .opened(content: .prompt(state))
            }
            
        case .startProcessing(let sessionID):
            let processingState = ProcessingState(sessionID: sessionID, startTime: Date())
            uiState = .opened(content: .processing(processingState))
            
        case .updateStreamingText(let text):
            if case .opened(.processing(var state)) = uiState {
                state.streamingText = text
                uiState = .opened(content: .processing(state))
            } else if case .closedProcessing(var state) = uiState {
                state.streamingText = text
                uiState = .closedProcessing(state)
            }
            
        case .completeProcessing(let resultText):
            var sessionID: String?
            if case .opened(.processing(let processingState)) = uiState {
                sessionID = processingState.sessionID
            } else if case .closedProcessing(let processingState) = uiState {
                sessionID = processingState.sessionID
            }
            if let sessionID = sessionID {
                let resultState = ResultState(sessionID: sessionID, streamingText: resultText)
                uiState = .opened(content: .result(resultState))
                promptStateCache.clearAll()
            }
            
        case .cancelProcessing:
            if case .closedProcessing = uiState {
                uiState = .closed
            } else {
                let promptState = promptStateCache
                uiState = .opened(content: .prompt(promptState))
            }
            
        case .failProcessing(let error, let canRetry):
            var promptState = promptStateCache
            promptState.errorMessage = error
            
            let wasClosedProcessing = uiState.isProcessingInBackground
            
            if wasClosedProcessing {
                uiState = .closed
                if canRetry {
                    pendingRetry = PendingRetryState(
                        parts: [],
                        agentID: promptState.selectedAgentID,
                        errorMessage: error
                    )
                }
            } else {
                uiState = .opened(content: .prompt(promptState))
            }
            
        case .showResult(let sessionID, let text):
            let resultState = ResultState(sessionID: sessionID, streamingText: text)
            uiState = .opened(content: .result(resultState))
            
        case .toggleResultExpanded:
            if case .opened(.result(var state)) = uiState {
                state.toggleExpanded()
                uiState = .opened(content: .result(state))
            }
            
        case .updateFollowUpText(let text):
            if case .opened(.result(var state)) = uiState {
                state.followUpText = text
                uiState = .opened(content: .result(state))
            }
            
        case .showMenu:
            uiState = .opened(content: .menu)
            
        case .hideMenu:
            let promptState = promptStateCache
            uiState = .opened(content: .prompt(promptState))
            
        case .startDictation(let previousPrompt):
            let dictationState = DictationState(phase: .recording, previousPromptState: previousPrompt)
            uiState = .opened(content: .dictating(dictationState))
            
        case .updateAudioLevel(let level):
            if case .opened(.dictating(var state)) = uiState {
                state.audioLevel = level
                uiState = .opened(content: .dictating(state))
            }
            
        case .startTranscribing:
            if case .opened(.dictating(var state)) = uiState {
                state.phase = .transcribing
                uiState = .opened(content: .dictating(state))
            }
            
        case .completeDictation(let transcription):
            if case .opened(.dictating(let state)) = uiState {
                var promptState = state.previousPromptState
                if let text = transcription {
                    if promptState.text.isEmpty {
                        promptState.text = text
                    } else {
                        promptState.text += " " + text
                    }
                }
                uiState = .opened(content: .prompt(promptState))
            }
            
        case .cancelDictation:
            if case .opened(.dictating(let state)) = uiState {
                uiState = .opened(content: .prompt(state.previousPromptState))
            }
            
        case .setPendingRetry(let state):
            pendingRetry = state
            
        case .clearPendingRetry:
            pendingRetry = nil
            
        case .executePendingRetry:
            pendingRetry?.incrementAttempt()
        }
    }
    
    private func logInvalidTransition(_ transition: NotchStateTransition) {
        print("[NotchStateMachine] Invalid transition: \(transition) from state: \(uiState)")
    }
}

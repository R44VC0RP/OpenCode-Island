//
//  NotchStateMachineTests.swift
//  OpenCodeIslandTests
//

import XCTest
@testable import OpenCode_Island

@MainActor
final class NotchStateMachineTests: XCTestCase {
    
    var stateMachine: NotchStateMachine!
    
    override func setUp() {
        super.setUp()
        stateMachine = NotchStateMachine()
    }
    
    override func tearDown() {
        stateMachine = nil
        super.tearDown()
    }
    
    // MARK: - Initial State
    
    func testInitialStateIsClosed() {
        XCTAssertEqual(stateMachine.uiState, .closed)
        XCTAssertTrue(stateMachine.isClosed)
        XCTAssertFalse(stateMachine.isOpen)
    }
    
    // MARK: - Hover Transitions
    
    func testHoverFromClosed() {
        let result = stateMachine.apply(.hover)
        
        XCTAssertTrue(result)
        XCTAssertEqual(stateMachine.uiState, .hovering)
    }
    
    func testUnhoverFromHovering() {
        _ = stateMachine.apply(.hover)
        let result = stateMachine.apply(.unhover)
        
        XCTAssertTrue(result)
        XCTAssertEqual(stateMachine.uiState, .closed)
    }
    
    func testHoverFromOpenedIsInvalid() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        let result = stateMachine.apply(.hover)
        
        XCTAssertFalse(result)
    }
    
    // MARK: - Open/Close Transitions
    
    func testOpenFromClosed() {
        let result = stateMachine.apply(.open(reason: .hotkey))
        
        XCTAssertTrue(result)
        XCTAssertTrue(stateMachine.isOpen)
        XCTAssertNotNil(stateMachine.currentPromptState)
    }
    
    func testOpenFromHovering() {
        _ = stateMachine.apply(.hover)
        let result = stateMachine.apply(.open(reason: .click))
        
        XCTAssertTrue(result)
        XCTAssertTrue(stateMachine.isOpen)
    }
    
    func testCloseFromOpened() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        let result = stateMachine.apply(.close)
        
        XCTAssertTrue(result)
        XCTAssertTrue(stateMachine.isClosed)
    }
    
    func testDismissClearsState() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.updatePromptText("test"))
        _ = stateMachine.apply(.dismiss)
        
        XCTAssertTrue(stateMachine.isClosed)
        _ = stateMachine.apply(.open(reason: .hotkey))
        XCTAssertEqual(stateMachine.currentPromptState?.text, "")
    }
    
    // MARK: - Prompt State Transitions
    
    func testUpdatePromptText() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        let result = stateMachine.apply(.updatePromptText("Hello"))
        
        XCTAssertTrue(result)
        XCTAssertEqual(stateMachine.currentPromptState?.text, "Hello")
    }
    
    func testSelectAgent() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.selectAgent("build"))
        
        XCTAssertEqual(stateMachine.currentPromptState?.selectedAgentID, "build")
        XCTAssertFalse(stateMachine.currentPromptState?.showAgentPicker ?? true)
    }
    
    func testToggleAgentPicker() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.toggleAgentPicker)
        
        XCTAssertTrue(stateMachine.currentPromptState?.showAgentPicker ?? false)
        
        _ = stateMachine.apply(.toggleAgentPicker)
        XCTAssertFalse(stateMachine.currentPromptState?.showAgentPicker ?? true)
    }
    
    func testSetAndClearError() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.setError("Connection failed"))
        
        XCTAssertEqual(stateMachine.currentPromptState?.errorMessage, "Connection failed")
        
        _ = stateMachine.apply(.clearError)
        XCTAssertNil(stateMachine.currentPromptState?.errorMessage)
    }
    
    func testAttachAndRemoveImage() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        
        let imageRef = AttachedImageRef(id: UUID(), mediaType: "image/png", dataSize: 1024)
        _ = stateMachine.apply(.attachImage(imageRef))
        
        XCTAssertEqual(stateMachine.currentPromptState?.attachedImages.count, 1)
        
        _ = stateMachine.apply(.removeImage(imageRef.id))
        XCTAssertEqual(stateMachine.currentPromptState?.attachedImages.count, 0)
    }
    
    // MARK: - Processing State Transitions
    
    func testStartProcessing() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        let result = stateMachine.apply(.startProcessing(sessionID: "session-1"))
        
        XCTAssertTrue(result)
        XCTAssertNotNil(stateMachine.currentProcessingState)
        XCTAssertEqual(stateMachine.currentProcessingState?.sessionID, "session-1")
    }
    
    func testUpdateStreamingText() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.startProcessing(sessionID: "session-1"))
        _ = stateMachine.apply(.updateStreamingText("Processing..."))
        
        XCTAssertEqual(stateMachine.currentProcessingState?.streamingText, "Processing...")
    }
    
    func testCompleteProcessing() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.startProcessing(sessionID: "session-1"))
        _ = stateMachine.apply(.completeProcessing(resultText: "Done!"))
        
        XCTAssertNotNil(stateMachine.currentResultState)
        XCTAssertEqual(stateMachine.currentResultState?.streamingText, "Done!")
    }
    
    func testCancelProcessing() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.startProcessing(sessionID: "session-1"))
        _ = stateMachine.apply(.cancelProcessing)
        
        XCTAssertNotNil(stateMachine.currentPromptState)
        XCTAssertNil(stateMachine.currentProcessingState)
    }
    
    func testFailProcessing() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.startProcessing(sessionID: "session-1"))
        _ = stateMachine.apply(.failProcessing(error: "Network error", canRetry: true))
        
        XCTAssertNotNil(stateMachine.currentPromptState)
        XCTAssertEqual(stateMachine.currentPromptState?.errorMessage, "Network error")
    }
    
    // MARK: - Result State Transitions
    
    func testShowResult() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.showResult(sessionID: "session-1", text: "Result text"))
        
        XCTAssertNotNil(stateMachine.currentResultState)
        XCTAssertEqual(stateMachine.currentResultState?.streamingText, "Result text")
    }
    
    func testToggleResultExpanded() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.showResult(sessionID: "session-1", text: "Result"))
        
        XCTAssertFalse(stateMachine.currentResultState?.isExpanded ?? true)
        
        _ = stateMachine.apply(.toggleResultExpanded)
        XCTAssertTrue(stateMachine.currentResultState?.isExpanded ?? false)
    }
    
    // MARK: - Menu Transitions
    
    func testShowAndHideMenu() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.showMenu)
        
        XCTAssertEqual(stateMachine.contentType, .menu)
        
        _ = stateMachine.apply(.hideMenu)
        XCTAssertNotNil(stateMachine.currentPromptState)
    }
    
    // MARK: - Dictation Transitions
    
    func testStartDictation() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        let promptState = stateMachine.currentPromptState!
        _ = stateMachine.apply(.startDictation(previousPrompt: promptState))
        
        XCTAssertNotNil(stateMachine.currentDictationState)
        XCTAssertTrue(stateMachine.currentDictationState?.isRecording ?? false)
    }
    
    func testCompleteDictation() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.updatePromptText("Hello "))
        let promptState = stateMachine.currentPromptState!
        _ = stateMachine.apply(.startDictation(previousPrompt: promptState))
        _ = stateMachine.apply(.completeDictation(transcription: "world"))
        
        XCTAssertNotNil(stateMachine.currentPromptState)
        XCTAssertEqual(stateMachine.currentPromptState?.text, "Hello  world")
    }
    
    func testCancelDictation() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.updatePromptText("Original"))
        let promptState = stateMachine.currentPromptState!
        _ = stateMachine.apply(.startDictation(previousPrompt: promptState))
        _ = stateMachine.apply(.cancelDictation)
        
        XCTAssertNotNil(stateMachine.currentPromptState)
        XCTAssertEqual(stateMachine.currentPromptState?.text, "Original")
    }
    
    // MARK: - Pending Retry
    
    func testSetAndClearPendingRetry() {
        let retryState = PendingRetryState(
            parts: [PromptPartRef(type: .text("test"))],
            agentID: nil,
            errorMessage: "Failed"
        )
        _ = stateMachine.apply(.setPendingRetry(retryState))
        
        XCTAssertTrue(stateMachine.hasPendingRetry)
        
        _ = stateMachine.apply(.clearPendingRetry)
        XCTAssertFalse(stateMachine.hasPendingRetry)
    }
    
    func testOpenWithPendingRetryClearsRetryAndShowsError() {
        let retryState = PendingRetryState(
            parts: [PromptPartRef(type: .text("test"))],
            agentID: nil,
            errorMessage: "Connection failed"
        )
        _ = stateMachine.apply(.setPendingRetry(retryState))
        
        let result = stateMachine.apply(.open(reason: .hotkey))
        
        XCTAssertTrue(result)
        XCTAssertTrue(stateMachine.isOpen)
        XCTAssertFalse(stateMachine.hasPendingRetry)
        XCTAssertEqual(stateMachine.currentPromptState?.errorMessage, "Connection failed")
    }
    
    // MARK: - Closed Processing State
    
    func testCloseWhileProcessingEntersClosedProcessing() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.startProcessing(sessionID: "session-1"))
        _ = stateMachine.apply(.close)
        
        XCTAssertTrue(stateMachine.isClosed)
        XCTAssertTrue(stateMachine.uiState.isProcessingInBackground)
        XCTAssertNotNil(stateMachine.backgroundProcessingState)
    }
    
    func testUpdateStreamingTextWorksInClosedProcessing() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.startProcessing(sessionID: "session-1"))
        _ = stateMachine.apply(.close)
        
        let result = stateMachine.apply(.updateStreamingText("Still processing..."))
        
        XCTAssertTrue(result)
        XCTAssertEqual(stateMachine.backgroundProcessingState?.streamingText, "Still processing...")
    }
    
    func testCompleteProcessingFromClosedOpensToResult() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.startProcessing(sessionID: "session-1"))
        _ = stateMachine.apply(.close)
        _ = stateMachine.apply(.completeProcessing(resultText: "Done!"))
        
        XCTAssertTrue(stateMachine.isOpen)
        XCTAssertNotNil(stateMachine.currentResultState)
        XCTAssertEqual(stateMachine.currentResultState?.streamingText, "Done!")
    }
    
    func testOpenFromClosedProcessingReopensToProcessing() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.startProcessing(sessionID: "session-1"))
        _ = stateMachine.apply(.updateStreamingText("In progress..."))
        _ = stateMachine.apply(.close)
        
        let result = stateMachine.apply(.open(reason: .click))
        
        XCTAssertTrue(result)
        XCTAssertTrue(stateMachine.isOpen)
        XCTAssertNotNil(stateMachine.currentProcessingState)
        XCTAssertEqual(stateMachine.currentProcessingState?.streamingText, "In progress...")
    }
    
    func testCancelProcessingFromClosedReturnsToNormalClosed() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.startProcessing(sessionID: "session-1"))
        _ = stateMachine.apply(.close)
        _ = stateMachine.apply(.cancelProcessing)
        
        XCTAssertTrue(stateMachine.isClosed)
        XCTAssertFalse(stateMachine.uiState.isProcessingInBackground)
        XCTAssertEqual(stateMachine.uiState, .closed)
    }
    
    // MARK: - Invalid Transitions
    
    func testPromptTransitionsInvalidWhenNotInPromptState() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.startProcessing(sessionID: "session-1"))
        
        XCTAssertFalse(stateMachine.apply(.updatePromptText("test")))
        XCTAssertFalse(stateMachine.apply(.toggleAgentPicker))
        XCTAssertFalse(stateMachine.apply(.setError("error")))
    }
    
    func testProcessingTransitionsInvalidWhenNotProcessing() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        
        XCTAssertFalse(stateMachine.apply(.updateStreamingText("test")))
        XCTAssertFalse(stateMachine.apply(.cancelProcessing))
    }
    
    // MARK: - State Preservation
    
    func testPromptStatePreservedOnClose() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.updatePromptText("Saved text"))
        _ = stateMachine.apply(.close)
        _ = stateMachine.apply(.open(reason: .hotkey))
        
        XCTAssertEqual(stateMachine.currentPromptState?.text, "Saved text")
    }
    
    func testPromptStateClearedOnDismiss() {
        _ = stateMachine.apply(.open(reason: .hotkey))
        _ = stateMachine.apply(.updatePromptText("Should be cleared"))
        _ = stateMachine.apply(.dismiss)
        _ = stateMachine.apply(.open(reason: .hotkey))
        
        XCTAssertEqual(stateMachine.currentPromptState?.text, "")
    }
}

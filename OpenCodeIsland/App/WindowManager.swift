//
//  WindowManager.swift
//  OpenCodeIsland
//
//  Manages the notch window lifecycle
//

import AppKit
import os.log

/// Logger for window management
private let logger = Logger(subsystem: "com.opencode.island", category: "Window")

struct PreservedViewModelState {
    let promptText: String
    let selectedAgentID: String?
    let attachedImages: [AttachedImage]
}

@MainActor
class WindowManager {
    private(set) var windowController: NotchWindowController?

    func setupNotchWindow() -> NotchWindowController? {
        let screenSelector = ScreenSelector.shared
        screenSelector.refreshScreens()

        guard let screen = screenSelector.selectedScreen else {
            logger.warning("No screen found")
            return nil
        }

        let preservedState = captureViewModelState()

        if let existingController = windowController {
            existingController.window?.orderOut(nil)
            existingController.window?.close()
            windowController = nil
        }

        windowController = NotchWindowController(screen: screen)
        windowController?.showWindow(nil)

        if let state = preservedState {
            restoreViewModelState(state)
        }

        return windowController
    }
    
    private func captureViewModelState() -> PreservedViewModelState? {
        guard let viewModel = windowController?.viewModel else { return nil }
        return PreservedViewModelState(
            promptText: viewModel.promptText,
            selectedAgentID: viewModel.selectedAgent?.id,
            attachedImages: viewModel.attachedImages
        )
    }
    
    private func restoreViewModelState(_ state: PreservedViewModelState) {
        guard let viewModel = windowController?.viewModel else { return }
        
        if !state.promptText.isEmpty {
            viewModel.promptText = state.promptText
        }
        
        if let agentID = state.selectedAgentID,
           let agent = viewModel.availableAgents.first(where: { $0.id == agentID }) {
            viewModel.selectAgent(agent)
        }
        
        viewModel.restoreAttachedImages(state.attachedImages)
    }
}

//
//  NotchViewModel.swift
//  ClaudeIsland
//
//  State management for the dynamic island prompt interface
//

import AppKit
import Combine
import SwiftUI

// MARK: - NSImage Extension

extension NSImage {
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmapImage.representation(using: .png, properties: [:])
    }
}

// MARK: - Enums

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason {
    case click
    case hover
    case hotkey
    case notification
    case boot
    case unknown
}

/// Content displayed in the opened notch
enum NotchContentType: Equatable {
    case prompt           // Main prompt input view
    case processing       // Working on a prompt (compact, stays visible while closed)
    case result           // Showing result
    case menu             // Settings menu
}

/// Whether the notch should show compact processing indicator when closed
extension NotchContentType {
    var showsCompactWhenClosed: Bool {
        self == .processing
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State
    
    @Published var status: NotchStatus = .closed
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .prompt
    @Published var isHovering: Bool = false
    
    // MARK: - Prompt State
    
    @Published var promptText: String = ""
    @Published var selectedAgent: Agent?
    @Published var showAgentPicker: Bool = false
    @Published var resultText: String = ""
    @Published var errorMessage: String?
    @Published var attachedImages: [AttachedImage] = []
    
    /// Represents an image attached to the prompt
    struct AttachedImage: Identifiable {
        let id = UUID()
        let image: NSImage
        let data: Data
        let mediaType: String
        
        var base64: String {
            data.base64EncodedString()
        }
    }
    
    // MARK: - OpenCode Service
    
    let openCodeService = OpenCodeService()
    
    /// Available agents from the server (primary agents only)
    var availableAgents: [Agent] {
        if openCodeService.agents.isEmpty {
            return Agent.fallback
        }
        return openCodeService.agents.map { Agent(from: $0) }
    }
    
    /// Connection state passthrough
    var connectionState: ConnectionState {
        openCodeService.connectionState
    }
    
    /// Whether we're currently processing a prompt
    var isProcessing: Bool {
        openCodeService.isProcessing
    }
    
    /// Available models from the server
    var availableModels: [ModelRef] {
        openCodeService.availableModels
    }
    
    // MARK: - Dependencies
    
    private let screenSelector = ScreenSelector.shared
    private let hotkeyManager = HotkeyManager.shared
    
    // MARK: - Geometry
    
    let geometry: NotchGeometry
    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool
    
    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }
    
    /// Dynamic opened size based on content type
    var openedSize: CGSize {
        switch contentType {
        case .prompt:
            return CGSize(
                width: min(screenRect.width * 0.45, 520),
                height: showAgentPicker ? 280 : 140
            )
        case .processing:
            // Processing view - compact, just shows "Working..." with cancel
            return CGSize(
                width: min(screenRect.width * 0.3, 320),
                height: 70
            )
        case .result:
            return CGSize(
                width: min(screenRect.width * 0.5, 600),
                height: 450
            )
        case .menu:
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 700  // Increased to accommodate model picker dropdown
            )
        }
    }
    
    // MARK: - Animation
    
    var animation: Animation {
        .easeOut(duration: 0.25)
    }
    
    // MARK: - Private
    
    private var cancellables = Set<AnyCancellable>()
    private let events = EventMonitors.shared
    private var hoverTimer: DispatchWorkItem?
    private var processingTask: Task<Void, Never>?
    
    // MARK: - Logging
    
    private func log(_ message: String) {
        print("[NotchViewModel] \(message)")
    }
    
    // MARK: - Initialization
    
    init(deviceNotchRect: CGRect, screenRect: CGRect, windowHeight: CGFloat, hasPhysicalNotch: Bool) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        
        setupEventHandlers()
        setupHotkeyHandler()
        setupServiceObservers()
        
        // Connect to OpenCode server on init
        Task {
            await connectToServer()
        }
    }
    
    // MARK: - Server Connection
    
    /// Connect to the OpenCode server
    func connectToServer() async {
        log("connectToServer() called")
        await openCodeService.connect()
        log("openCodeService.connect() completed, state: \(openCodeService.connectionState)")
        
        // Set default agent if we have a saved preference
        if let savedAgentID = AppSettings.defaultAgentID,
           let agent = availableAgents.first(where: { $0.id == savedAgentID }) {
            log("Setting saved default agent: \(savedAgentID)")
            selectedAgent = agent
        }
    }
    
    /// Reconnect to server (called from UI)
    func reconnect() {
        log("reconnect() called")
        openCodeService.reinitializeClient()
        Task {
            await connectToServer()
        }
    }
    
    /// Disconnect from server (called from UI)
    func disconnect() {
        log("disconnect() called")
        openCodeService.disconnect()
    }
    
    // MARK: - Event Handling
    
    private func setupEventHandlers() {
        events.mouseLocation
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)
        
        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMouseDown()
            }
            .store(in: &cancellables)
        
        events.keyDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleKeyDown(event)
            }
            .store(in: &cancellables)
    }
    
    private func setupServiceObservers() {
        // Forward all service changes to trigger view updates
        openCodeService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        
        // Observe streaming text changes
        openCodeService.$streamingText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self = self else { return }
                if self.contentType == .processing && !text.isEmpty {
                    self.resultText = text
                }
            }
            .store(in: &cancellables)
        
        // Observe processing state changes
        openCodeService.$isProcessing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isProcessing in
                guard let self = self else { return }
                if !isProcessing && self.contentType == .processing {
                    // Processing completed
                    if !self.resultText.isEmpty {
                        self.contentType = .result
                        // Auto-open to show the result
                        if self.status == .closed {
                            self.notchOpen(reason: .notification)
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    private func handleKeyDown(_ event: NSEvent) {
        // Only handle keys when opened
        guard status == .opened else { return }
        
        // Cmd+V - paste image (keyCode 9 = V)
        if event.keyCode == 9 && event.modifierFlags.contains(.command) {
            // Check if there's an image in the pasteboard
            if NSPasteboard.general.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue]) {
                pasteImageFromClipboard()
                // Don't return - let the text field also handle paste for text
            }
        }
        
        // Escape key (keyCode 53)
        if event.keyCode == 53 {
            if contentType == .result {
                dismiss()
            } else {
                notchClose()
            }
        }
    }
    
    private func setupHotkeyHandler() {
        hotkeyManager.activated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleHotkey()
            }
            .store(in: &cancellables)
    }
    
    private func handleHotkey() {
        if status == .opened {
            // If showing result, dismiss. Otherwise toggle.
            if contentType == .result {
                dismiss()
            } else {
                notchClose()
            }
        } else {
            notchOpen(reason: .hotkey)
        }
    }
    
    private func handleMouseMove(_ location: CGPoint) {
        let inNotch = geometry.isPointInNotch(location)
        let inOpened = status == .opened && geometry.isPointInOpenedPanel(location, size: openedSize)
        
        let newHovering = inNotch || inOpened
        
        guard newHovering != isHovering else { return }
        
        isHovering = newHovering
        
        // Cancel any pending hover timer
        hoverTimer?.cancel()
        hoverTimer = nil
        
        // Don't auto-expand on hover for prompt interface
        // Users should use hotkey to summon
    }
    
    private func handleMouseDown() {
        let location = NSEvent.mouseLocation
        
        switch status {
        case .opened:
            if geometry.isPointOutsidePanel(location, size: openedSize) {
                notchClose()
                repostClickAt(location)
            } else if geometry.notchScreenRect.contains(location) {
                // Clicking notch while opened - toggle menu vs prompt
                if contentType == .menu {
                    contentType = .prompt
                }
            }
        case .closed, .popping:
            if geometry.isPointInNotch(location) {
                notchOpen(reason: .click)
            }
        }
    }
    
    /// Re-posts a mouse click at the given screen location
    private func repostClickAt(_ location: CGPoint) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let screen = NSScreen.main else { return }
            let screenHeight = screen.frame.height
            let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)
            
            if let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseDown.post(tap: .cghidEventTap)
            }
            
            if let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseUp.post(tap: .cghidEventTap)
            }
        }
    }
    
    // MARK: - Actions
    
    func notchOpen(reason: NotchOpenReason = .unknown) {
        openReason = reason
        status = .opened
        
        // Don't reset state if we're processing or have a result - maintain state
        if contentType == .processing || contentType == .result {
            // Keep current state, just open
            return
        }
        
        // Reset to prompt view when opening fresh
        if reason == .hotkey || reason == .click {
            contentType = .prompt
            promptText = ""
            errorMessage = nil
            showAgentPicker = false
            
            // Use default agent if set
            if selectedAgent == nil, let defaultAgentID = AppSettings.defaultAgentID {
                selectedAgent = availableAgents.first { $0.id == defaultAgentID }
            }
        }
    }
    
    func notchClose() {
        status = .closed
        showAgentPicker = false
        
        // DON'T cancel processing when closing - let it continue in background
    }
    
    func dismiss() {
        // Cancel processing when explicitly dismissing
        Task {
            await openCodeService.abort()
        }
        
        notchClose()
        promptText = ""
        selectedAgent = nil
        resultText = ""
        errorMessage = nil
        contentType = .prompt
    }
    
    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }
    
    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }
    
    func toggleMenu() {
        contentType = contentType == .menu ? .prompt : .menu
    }
    
    // MARK: - Prompt Actions
    
    func submitPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedImages.isEmpty else { return }
        
        // Check for /new command
        if text.lowercased() == "/new" {
            startNewSession()
            return
        }
        
        // Check if server is connected
        guard connectionState.isConnected else {
            errorMessage = "Not connected to OpenCode server"
            return
        }
        
        // Clear any previous error
        errorMessage = nil
        
        // Build prompt parts (text + images)
        var parts: [PromptPart] = []
        
        // Add text part if present
        if !text.isEmpty {
            parts.append(.text(text))
        }
        
        // Add image parts
        for image in attachedImages {
            parts.append(.image(data: image.base64, mediaType: image.mediaType))
        }
        
        // Capture images for clearing after submit
        let submittedImages = attachedImages
        
        // Transition to processing
        contentType = .processing
        resultText = ""
        
        // Submit to OpenCode
        processingTask = Task {
            do {
                let result = try await openCodeService.submitPrompt(
                    parts: parts,
                    agentID: selectedAgent?.id
                )
                
                guard !Task.isCancelled else { return }
                
                self.resultText = result
                self.contentType = .result
                
                // Auto-open to show the result
                if self.status == .closed {
                    self.notchOpen(reason: .notification)
                }
                
                // Clear prompt for next input
                self.promptText = ""
                self.attachedImages = []
                
            } catch {
                guard !Task.isCancelled else { return }
                
                self.errorMessage = (error as? OpenCodeError)?.shortDescription ?? error.localizedDescription
                self.contentType = .prompt
            }
        }
    }
    
    /// Paste image from clipboard
    func pasteImageFromClipboard() {
        let pasteboard = NSPasteboard.general
        
        // Check for image data
        guard let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else {
            // No image in clipboard
            return
        }
        
        // Determine media type
        let mediaType: String
        if pasteboard.data(forType: .png) != nil {
            mediaType = "image/png"
        } else {
            mediaType = "image/tiff"
        }
        
        // Create NSImage for preview
        guard let image = NSImage(data: imageData) else { return }
        
        // Convert TIFF to PNG for consistency
        let finalData: Data
        let finalMediaType: String
        if mediaType == "image/tiff", let pngData = image.pngData() {
            finalData = pngData
            finalMediaType = "image/png"
        } else {
            finalData = imageData
            finalMediaType = mediaType
        }
        
        // Add to attached images
        let attachedImage = AttachedImage(
            image: image,
            data: finalData,
            mediaType: finalMediaType
        )
        attachedImages.append(attachedImage)
    }
    
    /// Remove an attached image
    func removeImage(_ image: AttachedImage) {
        attachedImages.removeAll { $0.id == image.id }
    }
    
    /// Clear all attached images
    func clearImages() {
        attachedImages.removeAll()
    }
    
    /// Start a new session (triggered by /new command)
    func startNewSession() {
        Task {
            do {
                _ = try await openCodeService.newSession()
                promptText = ""
                resultText = ""
                errorMessage = nil
                contentType = .prompt
            } catch {
                errorMessage = "Failed to create new session"
            }
        }
    }
    
    func selectAgent(_ agent: Agent) {
        selectedAgent = agent
        showAgentPicker = false
        
        // Remove the /agentname from prompt text
        if promptText.hasPrefix("/") {
            promptText = ""
        }
    }
    
    func clearAgent() {
        selectedAgent = nil
    }
    
    /// Set the default agent (persisted across sessions)
    func setDefaultAgent(_ agent: Agent?) {
        AppSettings.defaultAgentID = agent?.id
    }
    
    func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
    }
    
    /// Cancel current processing
    func cancelProcessing() {
        Task {
            await openCodeService.abort()
        }
        contentType = .prompt
    }
    
    /// Perform boot animation
    func performBootAnimation() {
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }
}

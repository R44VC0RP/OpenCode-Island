//
//  NotchViewModel.swift
//  OpenCodeIsland
//
//  State management for the dynamic island prompt interface
//

import AppKit
import Combine
import ScreenCaptureKit
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
    
    // MARK: - Dictation State
    
    @Published var isDictating: Bool = false
    @Published var isTranscribing: Bool = false
    
    /// Speech service for dictation
    let speechService = SpeechService.shared
    
    /// Tracks if we have a pending retry (error occurred in background)
    @Published var hasPendingRetry: Bool = false
    
    /// The prompt parts to retry if there's a pending retry
    private var pendingRetryParts: [PromptPart] = []
    private var pendingRetryAgentID: String?
    @Published var isResultExpanded: Bool = false
    
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
    
    /// Server port passthrough
    var serverPort: Int {
        OpenCodeServerManager.shared.serverPort
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
    
    /// Calculate extra height needed for multiline input (including word wrap)
    private var inputExtraHeight: CGFloat {
        let inputWidth: CGFloat = 420
        let horizontalPadding: CGFloat = 24
        let minHeight: CGFloat = 44
        let maxHeight: CGFloat = 120
        let verticalPadding: CGFloat = 24
        
        guard !promptText.isEmpty else {
            return 0
        }
        
        // Measure text height with word wrap
        let font = NSFont.systemFont(ofSize: 14)
        let textWidth = inputWidth - horizontalPadding
        let attributedString = NSAttributedString(
            string: promptText,
            attributes: [.font: font]
        )
        let boundingRect = attributedString.boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        
        let calculatedHeight = ceil(boundingRect.height) + verticalPadding
        let actualInputHeight = min(max(calculatedHeight, minHeight), maxHeight)
        
        // Return extra height beyond the minimum
        return max(0, actualInputHeight - minHeight)
    }
    
    /// Dynamic opened size based on content type
    var openedSize: CGSize {
        switch contentType {
        case .prompt:
            // Base height + dynamic input height for multiline
            let baseHeight: CGFloat = 160
            // Agent picker height: ~50px per agent row + padding, capped at 350px
            let agentCount = showAgentPicker ? CGFloat(availableAgents.count) : 0
            let agentPickerHeight: CGFloat = showAgentPicker ? min(agentCount * 50 + 16, 350) : 0
            let imagesHeight: CGFloat = attachedImages.isEmpty ? 0 : 80
            return CGSize(
                width: min(screenRect.width * 0.45, 520),
                height: baseHeight + agentPickerHeight + imagesHeight + inputExtraHeight
            )
        case .processing:
            // Processing view - compact, just shows "Working..." with cancel
            return CGSize(
                width: min(screenRect.width * 0.3, 320),
                height: 70
            )
        case .result:
            // Expanded mode: much taller and wider for full conversation history
            if isResultExpanded {
                return CGSize(
                    width: min(screenRect.width * 0.75, 900),
                    height: min(screenRect.height * 0.75, 800)
                )
            }
            return CGSize(
                width: min(screenRect.width * 0.55, 650),
                height: 500
            )
        case .menu:
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 950  // Increased to accommodate expanded dropdowns (agents + models + whisper)
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
        
        // Provide callback for dictation availability check
        hotkeyManager.canStartDictation = { [weak self] in
            guard let self = self else { return false }
            // Allow dictation if island is open in prompt mode and not already dictating
            return self.status == .opened && 
                   self.contentType == .prompt && 
                   !self.isDictating && 
                   !self.isTranscribing
        }
        
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
        
        // Forward server manager changes (for serverPort updates)
        OpenCodeServerManager.shared.objectWillChange
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
        
        // Cmd+S - capture screenshot (keyCode 1 = S)
        if event.keyCode == 1 && event.modifierFlags.contains(.command) {
            if contentType == .prompt {
                captureScreenshot()
                return
            }
        }
        
        // Cmd+V - paste image (keyCode 9 = V)
        if event.keyCode == 9 && event.modifierFlags.contains(.command) {
            // Check if there's an image in the pasteboard
            if NSPasteboard.general.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue]) {
                pasteImageFromClipboard()
                // Don't return - let the text field also handle paste for text
            }
        }
        
        // Enter key (keyCode 36) - submit prompt if in prompt mode
        // Shift+Enter inserts newline (handled by TextEditor naturally)
        if event.keyCode == 36 && contentType == .prompt {
            if !event.modifierFlags.contains(.shift) {
                // Plain Enter - submit
                submitPrompt()
            }
            // Shift+Enter - let TextEditor handle it (inserts newline)
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
        
        // Handle dictation start (user holds modifier after activation)
        hotkeyManager.dictationStarted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.startDictation()
            }
            .store(in: &cancellables)
        
        // Handle dictation end (user releases modifier)
        hotkeyManager.dictationEnded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.stopDictation()
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
        
        // Check for pending retry (background error that should auto-retry)
        if hasPendingRetry && (reason == .hotkey || reason == .click) {
            log("Notch opened with pending retry, auto-retrying...")
            executePendingRetry()
            return
        }
        
        // Switch to prompt view when opening, but preserve text and images
        if reason == .hotkey || reason == .click {
            contentType = .prompt
            // Don't clear promptText or attachedImages - preserve them when showing/hiding
            errorMessage = nil
            showAgentPicker = false
            
            // Use default agent if set (only if no agent selected)
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
        
        // Clear pending retry
        hasPendingRetry = false
        pendingRetryParts = []
        pendingRetryAgentID = nil
        
        notchClose()
        promptText = ""
        selectedAgent = nil
        resultText = ""
        errorMessage = nil
        contentType = .prompt
        isResultExpanded = false
    }
    
    /// Toggle expanded view for results
    func toggleExpanded() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isResultExpanded.toggle()
        }
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
        
        // Add image parts (using file type with data URL format)
        for image in attachedImages {
            parts.append(.image(base64Data: image.base64, mediaType: image.mediaType))
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
                
                // Fetch full conversation history for display
                await self.openCodeService.fetchConversationHistory()
                
                // Auto-open to show the result
                if self.status == .closed {
                    self.notchOpen(reason: .notification)
                }
                
                // Clear prompt for next input
                self.promptText = ""
                self.attachedImages = []
                
            } catch {
                guard !Task.isCancelled else { return }
                
                let openCodeError = error as? OpenCodeError
                self.errorMessage = openCodeError?.shortDescription ?? error.localizedDescription
                self.contentType = .prompt
                
                // If error is retryable and notch is closed (background error),
                // set up pending retry so it auto-retries when summoned
                if self.status == .closed {
                    let isRetryable = openCodeError?.isRetryable ?? false
                    if isRetryable {
                        self.hasPendingRetry = true
                        self.pendingRetryParts = parts
                        self.pendingRetryAgentID = self.selectedAgent?.id
                        self.log("Background error occurred, will auto-retry when summoned")
                    }
                }
            }
        }
    }
    
    /// Execute pending retry (called when notch is summoned after background error)
    private func executePendingRetry() {
        guard hasPendingRetry, !pendingRetryParts.isEmpty else { return }
        
        log("Auto-retrying after background error...")
        
        // Clear retry state
        hasPendingRetry = false
        let parts = pendingRetryParts
        let agentID = pendingRetryAgentID
        pendingRetryParts = []
        pendingRetryAgentID = nil
        
        // Clear error message
        errorMessage = nil
        
        // Transition to processing
        contentType = .processing
        resultText = ""
        
        // Submit to OpenCode
        processingTask = Task {
            do {
                let result = try await openCodeService.submitPrompt(
                    parts: parts,
                    agentID: agentID
                )
                
                guard !Task.isCancelled else { return }
                
                self.resultText = result
                self.contentType = .result
                
                // Clear prompt for next input
                self.promptText = ""
                self.attachedImages = []
                
            } catch {
                guard !Task.isCancelled else { return }
                
                let openCodeError = error as? OpenCodeError
                self.errorMessage = openCodeError?.shortDescription ?? error.localizedDescription
                self.contentType = .prompt
                
                // If still retryable, keep the retry pending
                if openCodeError?.isRetryable ?? false {
                    self.hasPendingRetry = true
                    self.pendingRetryParts = parts
                    self.pendingRetryAgentID = agentID
                }
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
    
    /// Capture a screenshot of the screen the app is on and attach it
    func captureScreenshot() {
        log("Capturing screenshot...")
        
        // Find the screen that contains the notch
        guard let screen = NSScreen.screens.first(where: { screen in
            screen.frame.intersects(CGRect(
                x: screenRect.midX - 1,
                y: screenRect.midY - 1,
                width: 2,
                height: 2
            ))
        }) ?? NSScreen.main else {
            log("Could not determine screen for screenshot")
            return
        }
        
        // Get the display ID for this screen
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            log("Could not get display ID")
            return
        }
        
        // Use ScreenCaptureKit for macOS 15+
        Task {
            await captureScreenWithScreenCaptureKit(displayID: displayID)
        }
    }
    
    /// Capture screen using ScreenCaptureKit (macOS 12.3+)
    private func captureScreenWithScreenCaptureKit(displayID: CGDirectDisplayID) async {
        do {
            // Get shareable content
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            
            // Find the display matching our displayID
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                log("Could not find display for screenshot")
                return
            }
            
            // Create a filter that captures the entire display (excluding our own window)
            let excludedApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            
            // Configure the screenshot
            let config = SCStreamConfiguration()
            config.width = Int(display.width) * 2  // Retina
            config.height = Int(display.height) * 2
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.scalesToFit = false
            config.showsCursor = false
            
            // Capture the screenshot
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            
            // Convert CGImage to NSImage
            let size = NSSize(width: image.width / 2, height: image.height / 2)  // Adjust for retina
            let nsImage = NSImage(cgImage: image, size: size)
            
            // Convert to PNG data
            guard let pngData = nsImage.pngData() else {
                log("Failed to convert screenshot to PNG")
                return
            }
            
            // Create attached image on main thread
            let attachedImage = AttachedImage(
                image: nsImage,
                data: pngData,
                mediaType: "image/png"
            )
            
            attachedImages.append(attachedImage)
            log("Screenshot captured and attached (\(pngData.count / 1024) KB)")
            
        } catch {
            log("Screenshot capture failed: \(error.localizedDescription)")
        }
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
    
    // MARK: - Dictation
    
    /// Start dictation mode (called when user holds modifier after hotkey activation)
    func startDictation() {
        log("startDictation() called - status: \(status), contentType: \(contentType)")
        
        guard status == .opened, contentType == .prompt else {
            log("Cannot start dictation - not in prompt mode")
            return
        }
        
        // Set dictating state immediately for visual feedback
        isDictating = true
        log("Dictation UI activated")
        
        Task {
            // Load model if needed
            if speechService.state == .idle {
                log("Loading speech model...")
                await speechService.loadModel()
            }
            
            // Wait for model to be ready
            guard speechService.state == .ready else {
                log("Speech service not ready: \(speechService.state)")
                isDictating = false
                return
            }
            
            // Start recording
            log("Starting audio recording...")
            let started = await speechService.startRecording()
            if started {
                log("Audio recording started successfully")
            } else {
                log("Failed to start audio recording")
                isDictating = false
            }
        }
    }
    
    /// Stop dictation and transcribe (called when user releases modifier)
    func stopDictation() {
        guard isDictating else { return }
        
        log("Stopping dictation...")
        isDictating = false
        isTranscribing = true
        
        Task {
            if let transcription = await speechService.stopRecordingAndTranscribe() {
                // Append transcription to prompt text
                if promptText.isEmpty {
                    promptText = transcription
                } else {
                    promptText += " " + transcription
                }
                log("Transcription added: \(transcription)")
            }
            isTranscribing = false
        }
    }
    
    /// Cancel dictation without transcribing
    func cancelDictation() {
        guard isDictating else { return }
        
        log("Cancelling dictation...")
        isDictating = false
        speechService.cancelRecording()
    }
}

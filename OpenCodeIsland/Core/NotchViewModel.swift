//
//  NotchViewModel.swift
//  OpenCodeIsland
//
//  State management for the dynamic island prompt interface.
//  Uses NotchStateMachine as the source of truth for state transitions.
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

// MARK: - Legacy Enums (for backward compatibility)

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

/// Content displayed in the opened notch
enum NotchContentType: Equatable {
    case prompt
    case processing
    case result
    case menu
    
    var showsCompactWhenClosed: Bool {
        self == .processing
    }
    
    /// Convert from NotchContentState
    init(from contentState: NotchContentState) {
        switch contentState {
        case .prompt: self = .prompt
        case .processing: self = .processing
        case .result: self = .result
        case .menu: self = .menu
        case .dictating: self = .prompt // Dictation is shown in prompt view
        }
    }
}

// MARK: - Attached Image

/// Represents an image attached to the prompt (with actual data)
struct AttachedImage: Identifiable {
    let id = UUID()
    let image: NSImage
    let data: Data
    let mediaType: String
    
    var base64: String {
        data.base64EncodedString()
    }
    
    /// Create ref for state machine
    var ref: AttachedImageRef {
        AttachedImageRef(id: id, mediaType: mediaType, dataSize: data.count)
    }
}

// MARK: - NotchViewModel

@MainActor
class NotchViewModel: ObservableObject {
    
    // MARK: - State Machine (Source of Truth)
    
    private let stateMachine = NotchStateMachine()
    
    // MARK: - UI Animation State (Not in state machine)
    
    @Published private var isPopping: Bool = false
    
    // MARK: - Attached Images (State machine only stores refs)
    
    @Published private(set) var attachedImages: [AttachedImage] = []
    
    // MARK: - Status Publisher (for external observers)
    
    private let statusSubject = CurrentValueSubject<NotchStatus, Never>(.closed)
    
    var statusPublisher: AnyPublisher<NotchStatus, Never> {
        statusSubject.removeDuplicates().eraseToAnyPublisher()
    }
    
    // MARK: - Computed State (Derived from state machine)
    
    var status: NotchStatus {
        if isPopping { return .popping }
        switch stateMachine.uiState {
        case .closed, .hovering, .closedProcessing:
            return .closed
        case .opened:
            return .opened
        }
    }
    
    var showsCompactProcessing: Bool {
        stateMachine.uiState.isProcessingInBackground
    }
    
    var backgroundProcessingText: String {
        stateMachine.backgroundProcessingState?.streamingText ?? ""
    }
    
    private func updateStatusSubject() {
        statusSubject.send(status)
    }
    
    var contentType: NotchContentType {
        guard let content = stateMachine.contentType else {
            return .prompt
        }
        return NotchContentType(from: content)
    }
    
    var isHovering: Bool {
        if case .hovering = stateMachine.uiState { return true }
        return false
    }
    
    var promptText: String {
        get { stateMachine.currentPromptState?.text ?? "" }
        set { _ = stateMachine.apply(.updatePromptText(newValue)) }
    }
    
    var showAgentPicker: Bool {
        get { stateMachine.currentPromptState?.showAgentPicker ?? false }
        set {
            if newValue != showAgentPicker {
                _ = stateMachine.apply(.toggleAgentPicker)
            }
        }
    }
    
    var errorMessage: String? {
        stateMachine.currentPromptState?.errorMessage
    }
    
    var resultText: String {
        stateMachine.currentResultState?.streamingText
            ?? stateMachine.currentProcessingState?.streamingText
            ?? ""
    }
    
    var isResultExpanded: Bool {
        stateMachine.currentResultState?.isExpanded ?? false
    }
    
    var isDictating: Bool {
        stateMachine.currentDictationState?.isRecording ?? false
    }
    
    var isTranscribing: Bool {
        stateMachine.currentDictationState?.isTranscribing ?? false
    }
    
    var hasPendingRetry: Bool {
        stateMachine.hasPendingRetry
    }
    
    // MARK: - Agent Selection (Local state with sync)
    
    @Published var selectedAgent: Agent?
    @Published private(set) var openReason: NotchOpenReason = .unknown
    
    // MARK: - OpenCode Service
    
    let openCodeService = OpenCodeService()
    
    var availableAgents: [Agent] {
        if openCodeService.agents.isEmpty {
            return Agent.fallback
        }
        return openCodeService.agents.map { Agent(from: $0) }
    }
    
    var connectionState: ConnectionState {
        openCodeService.connectionState
    }
    
    var serverPort: Int {
        OpenCodeServerManager.shared.serverPort
    }
    
    var isProcessing: Bool {
        openCodeService.isProcessing
    }
    
    var availableModels: [ModelRef] {
        openCodeService.availableModels
    }
    
    // MARK: - Speech Service
    
    let speechService = SpeechService.shared
    
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
    
    // MARK: - Private
    
    private var cancellables = Set<AnyCancellable>()
    private let events = EventMonitors.shared
    private var hoverTimer: DispatchWorkItem?
    private var processingTask: Task<Void, Never>?
    
    // MARK: - Input Extra Height Calculation
    
    private var inputExtraHeight: CGFloat {
        let inputWidth: CGFloat = 420
        let horizontalPadding: CGFloat = 24
        let minHeight: CGFloat = 44
        let maxHeight: CGFloat = 120
        let verticalPadding: CGFloat = 24
        
        guard !promptText.isEmpty else { return 0 }
        
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
        
        return max(0, actualInputHeight - minHeight)
    }
    
    var openedSize: CGSize {
        switch contentType {
        case .prompt:
            let baseHeight: CGFloat = 160
            let agentCount = showAgentPicker ? CGFloat(availableAgents.count) : 0
            let agentPickerHeight: CGFloat = showAgentPicker ? min(agentCount * 50 + 16, 350) : 0
            let imagesHeight: CGFloat = attachedImages.isEmpty ? 0 : 80
            return CGSize(
                width: min(screenRect.width * 0.45, 520),
                height: baseHeight + agentPickerHeight + imagesHeight + inputExtraHeight
            )
        case .processing:
            return CGSize(
                width: min(screenRect.width * 0.3, 320),
                height: 70
            )
        case .result:
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
                height: 950
            )
        }
    }
    
    var animation: Animation {
        .easeOut(duration: 0.25)
    }
    
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
        
        setupStateMachineObserver()
        setupEventHandlers()
        setupHotkeyHandler()
        setupServiceObservers()
        
        hotkeyManager.canStartDictation = { [weak self] in
            guard let self = self else { return false }
            return self.status == .opened &&
                   self.contentType == .prompt &&
                   !self.isDictating &&
                   !self.isTranscribing
        }
        
        Task {
            await connectToServer()
        }
    }
    
    // MARK: - State Machine Observer
    
    private func setupStateMachineObserver() {
        stateMachine.$uiState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.updateStatusSubject()
            }
            .store(in: &cancellables)
        
        $isPopping
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusSubject()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Server Connection
    
    func connectToServer() async {
        log("connectToServer() called")
        await openCodeService.connect()
        log("openCodeService.connect() completed, state: \(openCodeService.connectionState)")
        
        if let savedAgentID = AppSettings.defaultAgentID,
           let agent = availableAgents.first(where: { $0.id == savedAgentID }) {
            log("Setting saved default agent: \(savedAgentID)")
            selectedAgent = agent
        }
    }
    
    func reconnect() {
        log("reconnect() called")
        openCodeService.reinitializeClient()
        Task {
            await connectToServer()
        }
    }
    
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
        openCodeService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        
        OpenCodeServerManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        
        openCodeService.$streamingText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self = self, !text.isEmpty else { return }
                let hasProcessing = self.stateMachine.currentProcessingState != nil
                if hasProcessing {
                    _ = self.stateMachine.apply(.updateStreamingText(text))
                }
            }
            .store(in: &cancellables)
        
        openCodeService.$isProcessing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isProcessing in
                guard let self = self else { return }
                if !isProcessing {
                    let hasProcessing = self.stateMachine.currentProcessingState != nil
                    if hasProcessing {
                        let text = self.openCodeService.streamingText
                        if !text.isEmpty {
                            _ = self.stateMachine.apply(.completeProcessing(resultText: text))
                            if self.status == .closed {
                                self.notchOpen(reason: .notification)
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    private func handleKeyDown(_ event: NSEvent) {
        guard status == .opened else { return }
        
        // Cmd+S - capture screenshot
        if event.keyCode == 1 && event.modifierFlags.contains(.command) {
            if contentType == .prompt {
                captureScreenshot()
                return
            }
        }
        
        // Cmd+V - paste image
        if event.keyCode == 9 && event.modifierFlags.contains(.command) {
            if NSPasteboard.general.canReadItem(withDataConformingToTypes: [
                NSPasteboard.PasteboardType.png.rawValue,
                NSPasteboard.PasteboardType.tiff.rawValue
            ]) {
                pasteImageFromClipboard()
            }
        }
        
        // Enter key - submit prompt
        if event.keyCode == 36 && contentType == .prompt {
            if !event.modifierFlags.contains(.shift) {
                submitPrompt()
            }
        }
        
        // Escape key
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
        
        hotkeyManager.dictationStarted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.startDictation()
            }
            .store(in: &cancellables)
        
        hotkeyManager.dictationEnded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.stopDictation()
            }
            .store(in: &cancellables)
    }
    
    private func handleHotkey() {
        if status == .opened {
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
        
        if newHovering && !isHovering {
            _ = stateMachine.apply(.hover)
        } else if !newHovering && isHovering {
            _ = stateMachine.apply(.unhover)
        }
        
        hoverTimer?.cancel()
        hoverTimer = nil
    }
    
    private func handleMouseDown() {
        let location = NSEvent.mouseLocation
        
        switch status {
        case .opened:
            if geometry.isPointOutsidePanel(location, size: openedSize) {
                notchClose()
                repostClickAt(location)
            } else if geometry.notchScreenRect.contains(location) {
                if contentType == .menu {
                    _ = stateMachine.apply(.hideMenu)
                }
            }
        case .closed, .popping:
            if geometry.isPointInNotch(location) {
                notchOpen(reason: .click)
            }
        }
    }
    
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
        
        // Convert to state machine reason
        let smReason: NotchOpenReason
        switch reason {
        case .click: smReason = .click
        case .hover: smReason = .hover
        case .hotkey: smReason = .hotkey
        case .notification: smReason = .notification
        case .boot: smReason = .boot
        case .unknown: smReason = .unknown
        }
        
        if stateMachine.apply(.open(reason: smReason)) {
            // Set default agent if none selected
            if selectedAgent == nil, let defaultAgentID = AppSettings.defaultAgentID {
                selectedAgent = availableAgents.first { $0.id == defaultAgentID }
            }
            
            // Sync agent to state machine
            if let agent = selectedAgent {
                _ = stateMachine.apply(.selectAgent(agent.id))
            }
        }
        
        isPopping = false
    }
    
    func notchClose() {
        _ = stateMachine.apply(.close)
        isPopping = false
    }
    
    func dismiss() {
        processingTask?.cancel()
        processingTask = nil
        
        Task {
            await openCodeService.abort()
        }
        
        _ = stateMachine.apply(.dismiss)
        attachedImages.removeAll()
        selectedAgent = nil
        isPopping = false
    }
    
    func toggleExpanded() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            _ = stateMachine.apply(.toggleResultExpanded)
        }
    }
    
    func notchPop() {
        guard status == .closed else { return }
        isPopping = true
    }
    
    func notchUnpop() {
        guard isPopping else { return }
        isPopping = false
    }
    
    func toggleMenu() {
        if contentType == .menu {
            _ = stateMachine.apply(.hideMenu)
        } else {
            _ = stateMachine.apply(.showMenu)
        }
    }
    
    // MARK: - Prompt Actions
    
    func submitPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedImages.isEmpty else { return }
        
        if text.lowercased() == "/new" {
            startNewSession()
            return
        }
        
        guard connectionState.isConnected else {
            _ = stateMachine.apply(.setError("Not connected to OpenCode server"))
            return
        }
        
        _ = stateMachine.apply(.clearError)
        
        var parts: [PromptPart] = []
        if !text.isEmpty {
            parts.append(.text(text))
        }
        for image in attachedImages {
            parts.append(.image(base64Data: image.base64, mediaType: image.mediaType))
        }
        
        let sessionID = UUID().uuidString
        _ = stateMachine.apply(.startProcessing(sessionID: sessionID))
        
        processingTask = Task {
            do {
                let result = try await openCodeService.submitPrompt(
                    parts: parts,
                    agentID: selectedAgent?.id
                )
                
                guard !Task.isCancelled else { return }
                
                _ = stateMachine.apply(.completeProcessing(resultText: result))
                await openCodeService.fetchConversationHistory()
                
                if status == .closed {
                    notchOpen(reason: .notification)
                }
                
                attachedImages.removeAll()
                
            } catch {
                guard !Task.isCancelled else { return }
                
                let openCodeError = error as? OpenCodeError
                let errorMsg = openCodeError?.shortDescription ?? error.localizedDescription
                let isRetryable = openCodeError?.isRetryable ?? false
                
                _ = stateMachine.apply(.failProcessing(error: errorMsg, canRetry: isRetryable))
                
                if status == .closed && isRetryable {
                    let retryState = PendingRetryState(
                        parts: parts.map { part -> PromptPartRef in
                            switch part {
                            case .text(let text):
                                return PromptPartRef(type: .text(text))
                            case .file(let url, let mime, _):
                                return PromptPartRef(type: .image(base64: url, mediaType: mime))
                            }
                        },
                        agentID: selectedAgent?.id,
                        errorMessage: errorMsg
                    )
                    _ = stateMachine.apply(.setPendingRetry(retryState))
                    log("Background error occurred, will auto-retry when summoned")
                }
            }
        }
    }
    
    func pasteImageFromClipboard() {
        let pasteboard = NSPasteboard.general
        
        guard let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else {
            return
        }
        
        let mediaType: String
        if pasteboard.data(forType: .png) != nil {
            mediaType = "image/png"
        } else {
            mediaType = "image/tiff"
        }
        
        guard let image = NSImage(data: imageData) else { return }
        
        let finalData: Data
        let finalMediaType: String
        if mediaType == "image/tiff", let pngData = image.pngData() {
            finalData = pngData
            finalMediaType = "image/png"
        } else {
            finalData = imageData
            finalMediaType = mediaType
        }
        
        let attachedImage = AttachedImage(
            image: image,
            data: finalData,
            mediaType: finalMediaType
        )
        attachedImages.append(attachedImage)
        
        _ = stateMachine.apply(.attachImage(attachedImage.ref))
    }
    
    func removeImage(_ image: AttachedImage) {
        attachedImages.removeAll { $0.id == image.id }
        _ = stateMachine.apply(.removeImage(image.id))
    }
    
    func clearImages() {
        attachedImages.removeAll()
        _ = stateMachine.apply(.clearImages)
    }
    
    func restoreAttachedImages(_ images: [AttachedImage]) {
        for image in images {
            attachedImages.append(image)
            _ = stateMachine.apply(.attachImage(image.ref))
        }
    }
    
    func captureScreenshot() {
        log("Capturing screenshot...")
        
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
        
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            log("Could not get display ID")
            return
        }
        
        Task {
            await captureScreenWithScreenCaptureKit(displayID: displayID)
        }
    }
    
    private func captureScreenWithScreenCaptureKit(displayID: CGDirectDisplayID) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                log("Could not find display for screenshot")
                return
            }
            
            let excludedApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            
            let config = SCStreamConfiguration()
            config.width = Int(display.width) * 2
            config.height = Int(display.height) * 2
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.scalesToFit = false
            config.showsCursor = false
            
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            
            let size = NSSize(width: image.width / 2, height: image.height / 2)
            let nsImage = NSImage(cgImage: image, size: size)
            
            guard let pngData = nsImage.pngData() else {
                log("Failed to convert screenshot to PNG")
                return
            }
            
            let attachedImage = AttachedImage(
                image: nsImage,
                data: pngData,
                mediaType: "image/png"
            )
            
            attachedImages.append(attachedImage)
            _ = stateMachine.apply(.attachImage(attachedImage.ref))
            log("Screenshot captured and attached (\(pngData.count / 1024) KB)")
            
        } catch {
            log("Screenshot capture failed: \(error.localizedDescription)")
        }
    }
    
    func startNewSession() {
        Task {
            do {
                _ = try await openCodeService.newSession()
                attachedImages.removeAll()
                _ = stateMachine.apply(.dismiss)
                _ = stateMachine.apply(.open(reason: .unknown))
            } catch {
                _ = stateMachine.apply(.setError("Failed to create new session"))
            }
        }
    }
    
    func selectAgent(_ agent: Agent) {
        selectedAgent = agent
        _ = stateMachine.apply(.selectAgent(agent.id))
        
        if promptText.hasPrefix("/") {
            _ = stateMachine.apply(.updatePromptText(""))
        }
    }
    
    func clearAgent() {
        selectedAgent = nil
        _ = stateMachine.apply(.selectAgent(nil))
    }
    
    func setDefaultAgent(_ agent: Agent?) {
        AppSettings.defaultAgentID = agent?.id
    }
    
    func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
    }
    
    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        
        Task {
            await openCodeService.abort()
        }
        _ = stateMachine.apply(.cancelProcessing)
    }
    
    func performBootAnimation() {
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }
    
    // MARK: - Dictation
    
    func startDictation() {
        log("startDictation() called - status: \(status), contentType: \(contentType)")
        
        guard status == .opened, contentType == .prompt else {
            log("Cannot start dictation - not in prompt mode")
            return
        }
        
        guard let currentPrompt = stateMachine.currentPromptState else { return }
        _ = stateMachine.apply(.startDictation(previousPrompt: currentPrompt))
        log("Dictation UI activated")
        
        Task {
            if speechService.state == .idle {
                log("Loading speech model...")
                await speechService.loadModel()
            }
            
            guard speechService.state == .ready else {
                log("Speech service not ready: \(speechService.state)")
                _ = stateMachine.apply(.cancelDictation)
                return
            }
            
            log("Starting audio recording...")
            let started = await speechService.startRecording()
            if started {
                log("Audio recording started successfully")
            } else {
                log("Failed to start audio recording")
                _ = stateMachine.apply(.cancelDictation)
            }
        }
    }
    
    func stopDictation() {
        guard isDictating else { return }
        
        log("Stopping dictation...")
        _ = stateMachine.apply(.startTranscribing)
        
        Task {
            if let transcription = await speechService.stopRecordingAndTranscribe() {
                _ = stateMachine.apply(.completeDictation(transcription: transcription))
                log("Transcription added: \(transcription)")
            } else {
                _ = stateMachine.apply(.completeDictation(transcription: nil))
            }
        }
    }
    
    func cancelDictation() {
        guard isDictating else { return }
        
        log("Cancelling dictation...")
        speechService.cancelRecording()
        _ = stateMachine.apply(.cancelDictation)
    }
}

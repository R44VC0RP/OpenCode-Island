//
//  NotchView.swift
//  OpenCodeIsland
//
//  The main dynamic island SwiftUI view for prompt interface
//

import AppKit
import Combine
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @FocusState private var isInputFocused: Bool
    
    private var showCompactProcessing: Bool {
        viewModel.showsCompactProcessing
    }
    
    // MARK: - Sizing
    
    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }
    
    private var notchSize: CGSize {
        // When closed but processing, show opened width but only header height
        if showCompactProcessing {
            return CGSize(
                width: viewModel.openedSize.width,
                height: closedNotchSize.height
            )
        }
        
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }
    
    // MARK: - Corner Radii
    
    /// Whether to use opened styling (opened OR compact processing)
    private var useOpenedStyle: Bool {
        viewModel.status == .opened || showCompactProcessing
    }
    
    private var topCornerRadius: CGFloat {
        useOpenedStyle
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }
    
    private var bottomCornerRadius: CGFloat {
        useOpenedStyle
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }
    
    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }
    
    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    
    // MARK: - Body
    
    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                notchLayout
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        useOpenedStyle
                            ? cornerRadiusInsets.opened.top
                            : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], viewModel.status == .opened ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: (useOpenedStyle || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(
                        maxWidth: useOpenedStyle ? notchSize.width : nil,
                        maxHeight: useOpenedStyle ? notchSize.height : nil,
                        alignment: .top
                    )
                    .animation(viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status)
                    .animation(openAnimation, value: notchSize)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.showAgentPicker)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showCompactProcessing)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            isHovering = hovering
                        }
                    }
                    .onTapGesture {
                        if viewModel.status != .opened {
                            viewModel.notchOpen(reason: .click)
                        }
                    }
            }
        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            // Keep visible on non-notched devices
            if !viewModel.hasPhysicalNotch {
                isVisible = true
            }
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: viewModel.contentType) { oldContentType, newContentType in
            // Keep visible when processing starts (even if closed)
            if newContentType == .processing {
                isVisible = true
            }
            // Focus input when switching to prompt mode while opened
            if newContentType == .prompt && viewModel.status == .opened {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
    }
    
    // MARK: - Notch Layout
    
    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present (this sits behind the physical notch)
            headerRow
                .frame(height: max(24, closedNotchSize.height))
            
            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }
    
    // MARK: - Header Row
    
    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            // Show full header when opened OR when closed + processing
            if viewModel.status == .opened || showCompactProcessing {
                // Left side - sparkles icon or processing spinner
                if viewModel.contentType == .processing {
                    ProcessingSpinner()
                        .scaleEffect(0.8)
                        .padding(.leading, 8)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.leading, 8)
                }
                
                Spacer()
                
                // Menu toggle (only when opened, not in compact processing mode)
                if viewModel.status == .opened {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            viewModel.toggleMenu()
                        }
                    } label: {
                        Image(systemName: viewModel.contentType == .menu ? "xmark" : "gearshape")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // Closed state (not processing) - empty notch area
                Rectangle()
                    .fill(.clear)
                    .frame(width: closedNotchSize.width - 20)
            }
        }
        .frame(height: closedNotchSize.height)
    }
    
    // MARK: - Content View
    
    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.contentType {
            case .prompt:
                PromptInputView(viewModel: viewModel, isInputFocused: $isInputFocused)
            case .processing:
                ProcessingView(viewModel: viewModel)
            case .result:
                ResultView(viewModel: viewModel)
            case .menu:
                NotchMenuView(viewModel: viewModel)
            }
        }
        .frame(width: notchSize.width - 24)
    }
    
    // MARK: - Event Handlers
    
    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            // Focus input when opening via hotkey or click, as long as we're in prompt mode
            // This handles both fresh opens and returning to an existing conversation
            if (viewModel.openReason == .hotkey || viewModel.openReason == .click) && viewModel.contentType == .prompt {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        case .closed:
            guard viewModel.hasPhysicalNotch else { return }
            // Don't hide if we're processing - need to show compact indicator
            guard viewModel.contentType != .processing else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if viewModel.status == .closed && viewModel.contentType != .processing {
                    isVisible = false
                }
            }
        }
    }
}

// MARK: - Prompt Input View

struct PromptInputView: View {
    @ObservedObject var viewModel: NotchViewModel
    var isInputFocused: FocusState<Bool>.Binding
    
    /// Input box width (for text measurement)
    private let inputWidth: CGFloat = 420
    
    /// Calculate dynamic height based on actual rendered text (including word wrap)
    private var inputHeight: CGFloat {
        let minHeight: CGFloat = 44
        let maxHeight: CGFloat = 120
        let horizontalPadding: CGFloat = 24 // padding inside the text editor
        let verticalPadding: CGFloat = 24
        
        guard !viewModel.promptText.isEmpty else {
            return minHeight
        }
        
        // Measure text height with word wrap
        let font = NSFont.systemFont(ofSize: 14)
        let textWidth = inputWidth - horizontalPadding
        let attributedString = NSAttributedString(
            string: viewModel.promptText,
            attributes: [.font: font]
        )
        let boundingRect = attributedString.boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        
        let calculatedHeight = ceil(boundingRect.height) + verticalPadding
        return min(max(calculatedHeight, minHeight), maxHeight)
    }
    
    /// Whether content fits in single line (for centering)
    private var isSingleLine: Bool {
        inputHeight <= 44
    }
    
    /// Shortened working directory for display (replaces home with ~)
    /// Uses server's actual directory if connected, otherwise configured directory
    private var shortenedWorkingDirectory: String {
        let path = viewModel.openCodeService.serverWorkingDirectory ?? AppSettings.effectiveWorkingDirectory
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        } else if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Connection status indicator
            if !viewModel.connectionState.isConnected {
                ConnectionStatusBanner(viewModel: viewModel)
            }
            
            // Speech model loading indicator
            if viewModel.speechService.state == .loading {
                SpeechModelLoadingBanner(speechService: viewModel.speechService)
            }
            
            // Error message if any
            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.1))
                )
            }
            
            // Agent badge if selected
            if let agent = viewModel.selectedAgent {
                HStack {
                    AgentBadge(agent: agent) {
                        viewModel.clearAgent()
                    }
                    Spacer()
                }
            }
            
            // Text input OR dictation waveform
            if viewModel.isDictating || viewModel.isTranscribing {
                // Dictation mode - show waveform visualizer
                DictationWaveformView(
                    isDictating: viewModel.isDictating,
                    isTranscribing: viewModel.isTranscribing,
                    audioLevel: viewModel.speechService.audioLevel
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.95).combined(with: .opacity),
                    removal: .opacity
                ))
            } else {
                // Normal text input
                HStack(alignment: .bottom, spacing: 10) {
                    ZStack(alignment: isSingleLine ? .leading : .topLeading) {
                        // Placeholder - vertically centered
                        if viewModel.promptText.isEmpty {
                            Text("Ask anything... (/ for agents)")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.4))
                                .padding(.leading, 14)
                                .frame(height: 44)
                                .allowsHitTesting(false)
                        }
                        
                        // TextEditor for multiline input
                        TextEditor(text: $viewModel.promptText)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .focused(isInputFocused)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 10)
                            .padding(.vertical, isSingleLine ? 12 : 8)
                            .frame(height: inputHeight)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    )
                    .animation(.easeOut(duration: 0.15), value: inputHeight)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.iBeam.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .onChange(of: viewModel.promptText) { _, text in
                        // Show agent picker when typing /
                        if text == "/" {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                viewModel.showAgentPicker = true
                            }
                        } else if !text.hasPrefix("/") {
                            viewModel.showAgentPicker = false
                        }
                    }
                    
                    // Submit button
                    Button {
                        viewModel.submitPrompt()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(viewModel.promptText.isEmpty && viewModel.attachedImages.isEmpty ? .white.opacity(0.2) : .white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.promptText.isEmpty && viewModel.attachedImages.isEmpty)
                    .padding(.bottom, 8)
                }
                .transition(.opacity)
            }
            
            // Attached images preview
            if !viewModel.attachedImages.isEmpty {
                AttachedImagesPreview(viewModel: viewModel)
            }
            
            // Agent picker
            if viewModel.showAgentPicker {
                AgentPickerView(viewModel: viewModel)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
            
            // Working directory indicator
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(shortenedWorkingDirectory)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundColor(.white.opacity(0.25))
            
            // Keyboard hint
            HStack {
                Text("\u{21E7}Enter newline \u{2022} Enter send \u{2022} Esc dismiss \u{2022} \u{2318}V paste \u{2022} Hold hotkey to dictate")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isInputFocused.wrappedValue = true
            }
        }
        .onChange(of: viewModel.status) { _, newStatus in
            // Re-focus when opened (e.g., via hotkey)
            if newStatus == .opened {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused.wrappedValue = true
                }
            }
        }
    }
}

// MARK: - Attached Images Preview

struct AttachedImagesPreview: View {
    @ObservedObject var viewModel: NotchViewModel
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.attachedImages) { attachedImage in
                    AttachedImageThumbnail(
                        image: attachedImage,
                        onRemove: { viewModel.removeImage(attachedImage) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: 70)
    }
}

struct AttachedImageThumbnail: View {
    let image: AttachedImage
    let onRemove: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                )
            
            // Remove button (visible on hover)
            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .onHover { isHovering = $0 }
    }
}

// MARK: - Connection Status Banner

struct ConnectionStatusBanner: View {
    @ObservedObject var viewModel: NotchViewModel
    
    var body: some View {
        HStack(spacing: 8) {
            switch viewModel.connectionState {
            case .disconnected:
                Image(systemName: "wifi.slash")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                Text("Not connected")
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.9))
                Spacer()
                Button("Connect") {
                    viewModel.reconnect()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.15)))
                .buttonStyle(.plain)
                
            case .connecting:
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
                Text("Connecting...")
                    .font(.system(size: 12))
                    .foregroundColor(.yellow.opacity(0.9))
                Spacer()
                
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.orange.opacity(0.9))
                Spacer()
                Button("Retry") {
                    viewModel.reconnect()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.15)))
                .buttonStyle(.plain)
                
            case .connected:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.1))
        )
    }
}

// MARK: - Agent Badge

struct AgentBadge: View {
    let agent: Agent
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: agent.icon)
                .font(.system(size: 11))
            Text(agent.name)
                .font(.system(size: 12, weight: .medium))
            
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.15))
        )
    }
}

// MARK: - Agent Picker View

struct AgentPickerView: View {
    @ObservedObject var viewModel: NotchViewModel
    
    /// Track whether the view has appeared for animation
    @State private var hasAppeared = false
    
    private var filterText: String {
        if viewModel.promptText.hasPrefix("/") {
            return String(viewModel.promptText.dropFirst())
        }
        return ""
    }
    
    private var filteredAgents: [Agent] {
        let agents = viewModel.availableAgents
        if filterText.isEmpty {
            return agents
        }
        return agents.filter {
            $0.name.localizedCaseInsensitiveContains(filterText) ||
            $0.id.localizedCaseInsensitiveContains(filterText)
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(filteredAgents) { agent in
                    AgentRow(agent: agent) {
                        viewModel.selectAgent(agent)
                    }
                }
                
                if filteredAgents.isEmpty {
                    Text("No matching agents")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.vertical, 8)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: min(CGFloat(filteredAgents.count) * 50 + 16, 330))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : -8)
        .onAppear {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                hasAppeared = true
            }
        }
    }
}

struct AgentRow: View {
    let agent: Agent
    let onSelect: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: agent.icon)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                    Text(agent.description)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.white.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Processing View

struct ProcessingView: View {
    @ObservedObject var viewModel: NotchViewModel
    
    @State private var dotCount: Int = 1
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    
    private var dots: String {
        String(repeating: ".", count: dotCount)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            ProcessingSpinner()
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Working\(dots)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                
                if let agent = viewModel.selectedAgent {
                    Text("Using \(agent.name)")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            
            Spacer()
            
            Button {
                viewModel.dismiss()
            } label: {
                Text("Cancel")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .onReceive(timer) { _ in
            dotCount = (dotCount % 3) + 1
        }
    }
}

// MARK: - Result View

struct ResultView: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var followUpText: String = ""
    @FocusState private var isFollowUpFocused: Bool
    
    var body: some View {
        VStack(spacing: 12) {
            // Result header
            HStack {
                if let agent = viewModel.selectedAgent {
                    Image(systemName: agent.icon)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                    Text(agent.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                    Text("Complete")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                
                Spacer()
                
                // Copy button
                Button {
                    viewModel.copyResult()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                
                // Expand/collapse button
                Button {
                    viewModel.toggleExpanded()
                } label: {
                    Image(systemName: viewModel.isResultExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            
            // Conversation content with full history
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Show conversation history
                        ForEach(Array(viewModel.openCodeService.conversationHistory.enumerated()), id: \.element.info.id) { index, message in
                            ConversationMessageView(message: message)
                        }
                        
                        // If no history loaded yet, just show the result text
                        if viewModel.openCodeService.conversationHistory.isEmpty && !viewModel.resultText.isEmpty {
                            MarkdownText(viewModel.resultText, color: .white.opacity(0.9), fontSize: 13)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                    .id("bottom")
                }
                .frame(maxHeight: viewModel.isResultExpanded ? 550 : 280)
                .onAppear {
                    // Scroll to bottom on appear
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            // Follow-up prompt input
            HStack(spacing: 10) {
                TextField("Ask a follow-up...", text: $followUpText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .focused($isFollowUpFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    )
                    .onHover { hovering in
                        if hovering {
                            NSCursor.iBeam.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .onSubmit {
                        submitFollowUp()
                    }
                
                // Submit button
                Button {
                    submitFollowUp()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(followUpText.isEmpty ? .white.opacity(0.2) : .white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .disabled(followUpText.isEmpty)
            }
            
            // Keyboard hint
            Text("Enter to send \u{2022} Esc to dismiss \u{2022} \u{2318}S screenshot")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
    
    private func submitFollowUp() {
        guard !followUpText.isEmpty else { return }
        viewModel.promptText = followUpText
        followUpText = ""
        viewModel.submitPrompt()
    }
}

// MARK: - Conversation Message View

struct ConversationMessageView: View {
    let message: MessageWithParts
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Message role indicator
            HStack(spacing: 6) {
                Image(systemName: message.info.role == .user ? "person.fill" : "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(message.info.role == .user ? .blue : .purple)
                
                Text(message.info.role == .user ? "You" : "Assistant")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                
                if let agent = message.info.agent, message.info.role == .assistant {
                    Text("(\(agent))")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                
                Spacer()
            }
            
            // Message parts
            ForEach(message.parts) { part in
                ConversationPartView(part: part)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Conversation Part View

struct ConversationPartView: View {
    let part: MessagePart
    
    @State private var isExpanded: Bool = false
    
    var body: some View {
        Group {
            switch part.type {
            case .text:
                if let text = part.text, !text.isEmpty, part.synthetic != true {
                    MarkdownText(text, color: .white.opacity(0.9), fontSize: 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
            case .tool:
                ToolPartView(part: part, isExpanded: $isExpanded)
                
            case .reasoning:
                if let text = part.text, !text.isEmpty {
                    ReasoningPartView(text: text)
                }
                
            case .file:
                if let filename = part.filename ?? part.url {
                    FilePartView(filename: filename, mime: part.mime)
                }
                
            case .stepStart:
                // Visual separator for steps
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 1)
                    Text("Step")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 1)
                }
                .padding(.vertical, 4)
                
            case .stepFinish:
                // Show token/cost info if available
                if let tokens = part.tokens {
                    StepFinishView(reason: part.reason, tokens: tokens, cost: part.cost)
                }
                
            case .agent:
                if let name = part.name {
                    AgentPartView(name: name)
                }
                
            case .subtask:
                if let description = part.description {
                    SubtaskPartView(description: description, agent: part.agent)
                }
                
            case .retry:
                if let attempt = part.attempt {
                    RetryPartView(attempt: attempt, errorMessage: part.error?.data?.message)
                }
                
            case .snapshot, .patch, .compaction, .unknown:
                EmptyView()
            }
        }
    }
}

// MARK: - Tool Part View

struct ToolPartView: View {
    let part: MessagePart
    @Binding var isExpanded: Bool
    
    private var stateColor: Color {
        guard let state = part.state else { return .gray }
        if state.isRunning { return .orange }
        if state.isCompleted { return .green }
        if state.isError { return .red }
        return .gray
    }
    
    private var stateIcon: String {
        guard let state = part.state else { return "circle" }
        if state.isRunning { return "arrow.triangle.2.circlepath" }
        if state.isCompleted { return "checkmark.circle.fill" }
        if state.isError { return "exclamationmark.circle.fill" }
        return "circle"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tool header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    // Tool icon
                    Image(systemName: part.toolIcon)
                        .font(.system(size: 11))
                        .foregroundColor(stateColor)
                        .frame(width: 16)
                    
                    // Tool name
                    Text(part.toolDisplayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                    
                    // Tool input summary (file path, command, etc.)
                    if let summary = part.toolInputSummary {
                        Text(summary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    Spacer()
                    
                    // State indicator
                    if let state = part.state, state.isRunning {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: stateIcon)
                            .font(.system(size: 10))
                            .foregroundColor(stateColor)
                    }
                    
                    // Expand chevron
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(stateColor.opacity(0.3), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            
            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Show output if completed
                    if let output = part.state?.output, !output.isEmpty {
                        ToolOutputView(output: output, title: part.state?.title ?? "Output")
                    }
                    
                    // Show error if failed
                    if let error = part.state?.error, !error.isEmpty {
                        ToolErrorView(error: error)
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 6)
            }
        }
    }
}

// MARK: - Tool Output View

struct ToolOutputView: View {
    let output: String
    let title: String
    
    @State private var isFullyExpanded: Bool = false
    
    private var displayOutput: String {
        if isFullyExpanded || output.count < 500 {
            return output
        }
        return String(output.prefix(500)) + "..."
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                
                Spacer()
                
                if output.count > 500 {
                    Button {
                        isFullyExpanded.toggle()
                    } label: {
                        Text(isFullyExpanded ? "Show less" : "Show more")
                            .font(.system(size: 10))
                            .foregroundColor(.blue.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            
            ScrollView(.vertical, showsIndicators: true) {
                Text(displayOutput)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: isFullyExpanded ? 300 : 100)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.3))
            )
        }
    }
}

// MARK: - Tool Error View

struct ToolErrorView: View {
    let error: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.red)
            
            Text(error)
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.9))
                .lineLimit(3)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.red.opacity(0.1))
        )
    }
}

// MARK: - Reasoning Part View

struct ReasoningPartView: View {
    let text: String
    
    @State private var isExpanded: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11))
                        .foregroundColor(.purple.opacity(0.8))
                    
                    Text("Reasoning")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.purple.opacity(0.8))
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.purple.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .italic()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
    }
}

// MARK: - File Part View

struct FilePartView: View {
    let filename: String
    let mime: String?
    
    private var icon: String {
        guard let mime = mime else { return "doc" }
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "video" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" { return "doc.richtext" }
        return "doc"
    }
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.blue.opacity(0.8))
            
            Text(filename)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.blue.opacity(0.1))
        )
    }
}

// MARK: - Step Finish View

struct StepFinishView: View {
    let reason: String?
    let tokens: MessagePart.PartTokens
    let cost: Double?
    
    var body: some View {
        HStack(spacing: 8) {
            if let input = tokens.input, let output = tokens.output {
                Text("\(input) in / \(output) out tokens")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
            
            if let cost = cost, cost > 0 {
                Text(String(format: "$%.4f", cost))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Agent Part View

struct AgentPartView: View {
    let name: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 11))
                .foregroundColor(.cyan.opacity(0.8))
            
            Text("Agent: \(name)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.cyan.opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.cyan.opacity(0.1))
        )
    }
}

// MARK: - Subtask Part View

struct SubtaskPartView: View {
    let description: String
    let agent: String?
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundColor(.orange.opacity(0.8))
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Subtask")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange.opacity(0.8))
                
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
            }
            
            Spacer()
            
            if let agent = agent {
                Text(agent)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.1))
        )
    }
}

// MARK: - Retry Part View

struct RetryPartView: View {
    let attempt: Int
    let errorMessage: String?
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11))
                .foregroundColor(.yellow.opacity(0.8))
            
            Text("Retry attempt \(attempt)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.yellow.opacity(0.8))
            
            if let error = errorMessage {
                Text("- \(error)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.yellow.opacity(0.1))
        )
    }
}

// MARK: - Dictation Waveform View

struct DictationWaveformView: View {
    let isDictating: Bool
    let isTranscribing: Bool
    let audioLevel: Float
    
    private let barCount = 24
    
    var body: some View {
        HStack(spacing: 8) {
            // Microphone icon - smaller
            ZStack {
                Circle()
                    .fill(isDictating ? Color.red : Color.orange)
                    .frame(width: 28, height: 28)
                
                Image(systemName: isDictating ? "mic.fill" : "waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.leading, 10)
            
            // Waveform bars - reactive to audio
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    AudioLevelBar(
                        index: index, 
                        barCount: barCount,
                        audioLevel: audioLevel,
                        isActive: isDictating
                    )
                }
            }
            
            Spacer()
            
            // Status text - more compact
            if isTranscribing {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("Transcribing...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.trailing, 10)
            } else {
                Text("Release to stop")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.trailing, 10)
            }
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDictating ? Color.red.opacity(0.12) : Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isDictating ? Color.red.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

struct AudioLevelBar: View {
    let index: Int
    let barCount: Int
    let audioLevel: Float
    let isActive: Bool
    
    @State private var animatedHeight: CGFloat = 3
    @State private var animationPhase: Double = 0
    
    // Calculate target height with wave animation
    private var targetHeight: CGFloat {
        guard isActive else { return 3 }
        
        // Create a flowing wave pattern
        let center = CGFloat(barCount) / 2.0
        let distanceFromCenter = abs(CGFloat(index) - center) / center
        
        // Wave that travels across the bars
        let phase = animationPhase + Double(index) * 0.3
        let wave = (sin(phase) + 1) / 2  // 0 to 1
        
        // Bars in middle are taller
        let centerBoost = 1.0 - (distanceFromCenter * 0.4)
        
        // Calculate final height
        let baseHeight: CGFloat = 6
        let maxHeight: CGFloat = 22
        let height = baseHeight + (maxHeight - baseHeight) * wave * centerBoost
        
        return height
    }
    
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(isActive ? Color.red.opacity(0.8) : Color.orange.opacity(0.5))
            .frame(width: 2, height: animatedHeight)
            .onAppear {
                if isActive {
                    startAnimation()
                }
            }
            .onChange(of: isActive) { _, active in
                if active {
                    startAnimation()
                } else {
                    animatedHeight = 3
                }
            }
    }
    
    private func startAnimation() {
        // Continuous wave animation
        withAnimation(.linear(duration: 0.1)) {
            animatedHeight = targetHeight
        }
        
        // Update phase continuously
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { timer in
            if !isActive {
                timer.invalidate()
                return
            }
            animationPhase += 0.4
            withAnimation(.easeInOut(duration: 0.08)) {
                animatedHeight = targetHeight
            }
        }
    }
}

// MARK: - Speech Model Loading Banner

struct SpeechModelLoadingBanner: View {
    @ObservedObject var speechService: SpeechService
    
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Loading Whisper Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                
                Text(speechService.loadingProgress.isEmpty ? speechService.currentModelName : speechService.loadingProgress)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.15))
        )
    }
}



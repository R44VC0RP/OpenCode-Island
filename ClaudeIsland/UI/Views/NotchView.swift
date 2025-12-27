//
//  NotchView.swift
//  ClaudeIsland
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
    
    /// Whether to show compact processing indicator (pill expands slightly)
    private var showCompactProcessing: Bool {
        viewModel.status == .closed && viewModel.contentType == .processing
    }
    
    // MARK: - Sizing
    
    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }
    
    /// Extra width for the compact processing indicator
    /// Expands the notch to show spinner + "Processing..." below notch
    private var compactExpansionWidth: CGFloat {
        showCompactProcessing ? 80 : 0
    }
    
    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }
    
    // MARK: - Corner Radii
    
    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }
    
    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
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
                        viewModel.status == .opened
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
                        color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        maxHeight: viewModel.status == .opened ? notchSize.height : nil,
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
        .onChange(of: viewModel.contentType) { _, newContentType in
            // Keep visible when processing starts (even if closed)
            if newContentType == .processing {
                isVisible = true
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
            
            // Compact processing indicator - shows BELOW the notch when closed + processing
            if showCompactProcessing {
                compactProcessingIndicator
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            
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
    
    // MARK: - Compact Processing Indicator
    
    @ViewBuilder
    private var compactProcessingIndicator: some View {
        HStack(spacing: 8) {
            ProcessingSpinner()
                .scaleEffect(1.0)
            Text("Processing...")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: closedNotchSize.width + compactExpansionWidth)
    }
    
    // MARK: - Header Row
    
    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            // Left side - icon when opened
            if viewModel.status == .opened {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.leading, 8)
                
                Spacer()
                
                // Menu toggle
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
            } else {
                // Closed state - empty (notch area)
                Rectangle()
                    .fill(.clear)
                    .frame(width: showCompactProcessing ? closedNotchSize.width + compactExpansionWidth : closedNotchSize.width - 20)
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
            // Focus input when opening via hotkey
            if viewModel.openReason == .hotkey && viewModel.contentType == .prompt {
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
    
    var body: some View {
        VStack(spacing: 12) {
            // Connection status indicator
            if !viewModel.connectionState.isConnected {
                ConnectionStatusBanner(viewModel: viewModel)
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
            
            // Text input
            HStack(spacing: 10) {
                TextField("Ask anything... (/ for agents)", text: $viewModel.promptText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .focused(isInputFocused)
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
                        viewModel.submitPrompt()
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
            
            // Keyboard hint
            HStack {
                Text("Enter to send \u{2022} Esc to dismiss \u{2022} \u{2318}V to paste images")
                    .font(.system(size: 11))
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
    let image: NotchViewModel.AttachedImage
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
                
                // Copy button in header
                Button {
                    viewModel.copyResult()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            
            // Result content
            ScrollView {
                MarkdownText(viewModel.resultText, color: .white.opacity(0.9), fontSize: 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            
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
            Text("Enter to send \u{2022} Esc to dismiss")
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

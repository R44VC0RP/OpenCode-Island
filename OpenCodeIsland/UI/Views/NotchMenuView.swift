//
//  NotchMenuView.swift
//  OpenCodeIsland
//
//  Settings menu for OpenCode Island
//

import ApplicationServices
import Combine
import ServiceManagement
import Sparkle
import SwiftUI

// MARK: - NotchMenuView

struct NotchMenuView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var hotkeyManager = HotkeyManager.shared
    @State private var launchAtLogin: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                // Back button
                MenuRow(
                    icon: "chevron.left",
                    label: "Back"
                ) {
                    viewModel.toggleMenu()
                }

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)
                
                // Server connection status
                ServerStatusRow(viewModel: viewModel)
                
                // Working directory
                WorkingDirectoryRow(viewModel: viewModel)

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)

                // Hotkey settings
                HotkeyPickerRow(selection: $hotkeyManager.hotkey)

                // Appearance settings
                ScreenPickerRow()

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)

                // System settings
                MenuToggleRow(
                    icon: "power",
                    label: "Launch at Login",
                    isOn: launchAtLogin
                ) {
                    do {
                        if launchAtLogin {
                            try SMAppService.mainApp.unregister()
                            launchAtLogin = false
                        } else {
                            try SMAppService.mainApp.register()
                            launchAtLogin = true
                        }
                    } catch {
                        print("Failed to toggle launch at login: \(error)")
                    }
                }

                AccessibilityRow(isEnabled: AXIsProcessTrusted())

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)

                // Agents section with default agent picker
                AgentsSection(viewModel: viewModel)
                
                // Models section with default model picker
                ModelsSection(viewModel: viewModel)
                
                // Whisper model section for speech-to-text
                WhisperModelSection()

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)

                // About / Updates
                AboutRow()
                
                // Quit
                QuitRow()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            refreshStates()
        }
        .onChange(of: viewModel.contentType) { _, newValue in
            if newValue == .menu {
                refreshStates()
            }
        }
    }

    private func refreshStates() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        screenSelector.refreshScreens()
    }
}

// MARK: - Server Status Row

struct ServerStatusRow: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 12))
                .foregroundColor(statusColor)
                .frame(width: 16)
            
            Text("OpenCode Server")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))
            
            Spacer()
            
            if case .connected = viewModel.connectionState {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text(verbatim: "Port \(viewModel.serverPort)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
            } else if case .connecting = viewModel.connectionState {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
                Text("Starting...")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            } else if case .error(let message) = viewModel.connectionState {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .lineLimit(1)
            } else {
                Button("Connect") {
                    viewModel.reconnect()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.15)))
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
    
    private var statusIcon: String {
        switch viewModel.connectionState {
        case .connected:
            return "checkmark.circle.fill"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .disconnected:
            return "wifi.slash"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private var statusColor: Color {
        switch viewModel.connectionState {
        case .connected:
            return TerminalColors.green
        case .connecting:
            return .yellow
        case .disconnected:
            return .white.opacity(0.5)
        case .error:
            return .orange
        }
    }
}

// MARK: - Working Directory Row

struct WorkingDirectoryRow: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var isHovered = false
    @State private var isExpanded = false
    
    private var displayPath: String {
        let path = AppSettings.effectiveWorkingDirectory
        // Show abbreviated path
        if path == NSHomeDirectory() {
            return "~ (Home)"
        }
        // Replace home directory with ~
        if path.hasPrefix(NSHomeDirectory()) {
            return "~" + path.dropFirst(NSHomeDirectory().count)
        }
        return path
    }
    
    var body: some View {
        VStack(spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))
                        .frame(width: 16)
                    
                    Text("Working Directory")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))
                    
                    Spacer()
                    
                    Text(displayPath)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            
            if isExpanded {
                WorkingDirectoryDropdown(viewModel: viewModel, isExpanded: $isExpanded)
            }
        }
    }
}

private struct WorkingDirectoryDropdown: View {
    @ObservedObject var viewModel: NotchViewModel
    @Binding var isExpanded: Bool
    @State private var hasAppeared = false
    @State private var customPath: String = AppSettings.workingDirectory ?? ""
    
    var body: some View {
        VStack(spacing: 8) {
            // Current path display
            HStack {
                Text("Current: ")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                Text(AppSettings.effectiveWorkingDirectory)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            
            // Browse button
            Button {
                browseForDirectory()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                    Text("Browse...")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
            
            // Reset to home button
            if AppSettings.workingDirectory != nil {
                Button {
                    AppSettings.workingDirectory = nil
                    customPath = ""
                    restartServerIfNeeded()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "house")
                            .font(.system(size: 11))
                        Text("Reset to Home Directory")
                            .font(.system(size: 11))
                        Spacer()
                    }
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
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
    
    private func browseForDirectory() {
        // Close the dropdown first to avoid z-order issues
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            isExpanded = false
        }
        
        // Delay slightly to let the animation complete, then show panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = "Select"
            panel.message = "Choose working directory for OpenCode"
            panel.directoryURL = URL(fileURLWithPath: AppSettings.effectiveWorkingDirectory)
            panel.level = .floating  // Ensure it appears above other windows
            
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    DispatchQueue.main.async {
                        AppSettings.workingDirectory = url.path
                        self.customPath = url.path
                        self.restartServerIfNeeded()
                    }
                }
            }
        }
    }
    
    private func restartServerIfNeeded() {
        // Restart the server with new directory
        Task {
            await OpenCodeServerManager.shared.restartServer()
            // Reconnect after server restarts
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run {
                viewModel.reconnect()
            }
        }
    }
}

// MARK: - Hotkey Picker Row

struct HotkeyPickerRow: View {
    @Binding var selection: HotkeyType
    @State private var isExpanded = false
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 4) {
            // Current selection
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "command")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))
                        .frame(width: 16)

                    Text("Summon Hotkey")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                    Spacer()

                    Text(selection.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Options dropdown
            if isExpanded {
                HotkeyOptionsDropdown(selection: $selection, isExpanded: $isExpanded)
            }
        }
    }
}

/// Separate view for animated dropdown content
private struct HotkeyOptionsDropdown: View {
    @Binding var selection: HotkeyType
    @Binding var isExpanded: Bool
    @State private var hasAppeared = false
    
    var body: some View {
        VStack(spacing: 2) {
            ForEach(HotkeyType.presets.indices, id: \.self) { index in
                let preset = HotkeyType.presets[index]
                HotkeyOptionRow(
                    hotkey: preset,
                    isSelected: selection == preset
                ) {
                    selection = preset
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isExpanded = false
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
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

struct HotkeyOptionRow: View {
    let hotkey: HotkeyType
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Text(hotkey.displayName)
                    .font(.system(size: 13))
                    .foregroundColor(.white)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.white.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Agents Section

struct AgentsSection: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var isExpanded = false
    @State private var isHovered = false
    
    private var agents: [Agent] {
        viewModel.availableAgents
    }
    
    private var defaultAgentName: String {
        if let defaultID = AppSettings.defaultAgentID,
           let agent = agents.first(where: { $0.id == defaultID }) {
            return agent.name
        }
        return "None"
    }

    var body: some View {
        VStack(spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.2")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))
                        .frame(width: 16)

                    Text("Default Agent")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                    Spacer()

                    Text(defaultAgentName)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                AgentsDropdown(viewModel: viewModel, isExpanded: $isExpanded)
            }
        }
    }
}

/// Separate view for animated dropdown content
private struct AgentsDropdown: View {
    @ObservedObject var viewModel: NotchViewModel
    @Binding var isExpanded: Bool
    @State private var hasAppeared = false
    
    private var agents: [Agent] {
        viewModel.availableAgents
    }
    
    var body: some View {
        VStack(spacing: 2) {
            // "None" option to clear default
            AgentDefaultRow(
                agent: nil,
                isSelected: AppSettings.defaultAgentID == nil
            ) {
                viewModel.setDefaultAgent(nil)
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded = false
                }
            }
            
            ForEach(agents) { agent in
                AgentDefaultRow(
                    agent: agent,
                    isSelected: AppSettings.defaultAgentID == agent.id
                ) {
                    viewModel.setDefaultAgent(agent)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isExpanded = false
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
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

/// Row for selecting default agent
private struct AgentDefaultRow: View {
    let agent: Agent?
    let isSelected: Bool
    let onSelect: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                if let agent = agent {
                    Image(systemName: agent.icon)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 16)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                        Text(agent.description)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 16)
                    
                    Text("None")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.white.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Models Section

struct ModelsSection: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var searchText = ""
    
    private var models: [ModelRef] {
        viewModel.openCodeService.availableModels
    }
    
    private var defaultModelName: String {
        if let defaultID = AppSettings.defaultModelID,
           let model = models.first(where: { $0.id == defaultID }) {
            return model.displayName
        }
        return "Server Default"
    }

    var body: some View {
        VStack(spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                    if !isExpanded {
                        searchText = ""
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "cpu")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))
                        .frame(width: 16)

                    Text("Default Model")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                    Spacer()

                    Text(defaultModelName)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                ModelsDropdown(
                    models: models,
                    searchText: $searchText,
                    isExpanded: $isExpanded
                )
            }
        }
    }
}

/// Dropdown for selecting default model with search
private struct ModelsDropdown: View {
    let models: [ModelRef]
    @Binding var searchText: String
    @Binding var isExpanded: Bool
    @State private var hasAppeared = false
    @FocusState private var isSearchFocused: Bool
    
    private var filteredModels: [ModelRef] {
        if searchText.isEmpty {
            return models
        }
        return models.filter { model in
            model.displayName.localizedCaseInsensitiveContains(searchText) ||
            model.modelID.localizedCaseInsensitiveContains(searchText) ||
            model.providerID.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                
                TextField("Search models...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .focused($isSearchFocused)
                
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.iBeam.push()
                } else {
                    NSCursor.pop()
                }
            }
            
            // Models list
            if filteredModels.isEmpty && searchText.isEmpty {
                Text("No models available")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
            } else if filteredModels.isEmpty {
                Text("No matching models")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        // "Server Default" option (only show if not searching)
                        if searchText.isEmpty {
                            ModelDefaultRow(
                                model: nil,
                                isSelected: AppSettings.defaultModelID == nil
                            ) {
                                AppSettings.defaultModelID = nil
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    isExpanded = false
                                }
                            }
                        }
                        
                        ForEach(filteredModels) { model in
                            ModelDefaultRow(
                                model: model,
                                isSelected: AppSettings.defaultModelID == model.id
                            ) {
                                AppSettings.defaultModelID = model.id
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    isExpanded = false
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: min(CGFloat(filteredModels.count + (searchText.isEmpty ? 1 : 0)) * 32, 200))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
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
            // Focus search field
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isSearchFocused = true
            }
        }
    }
}

/// Row for selecting default model
private struct ModelDefaultRow: View {
    let model: ModelRef?
    let isSelected: Bool
    let onSelect: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                if let model = model {
                    Image(systemName: "cpu")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 16)
                    
                    Text(model.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                } else {
                    Image(systemName: "server.rack")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 16)
                    
                    Text("Server Default")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.white.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Whisper Model Section

struct WhisperModelSection: View {
    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var selectedModel = AppSettings.whisperModel
    
    var body: some View {
        VStack(spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))
                        .frame(width: 16)

                    Text("Whisper Model")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                    Spacer()

                    Text(selectedModel.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                WhisperModelDropdown(
                    selectedModel: $selectedModel,
                    isExpanded: $isExpanded
                )
            }
        }
    }
}

/// Dropdown for selecting Whisper model
private struct WhisperModelDropdown: View {
    @Binding var selectedModel: WhisperModel
    @Binding var isExpanded: Bool
    @State private var hasAppeared = false
    
    var body: some View {
        VStack(spacing: 2) {
            ForEach(WhisperModel.allCases, id: \.self) { model in
                WhisperModelRow(
                    model: model,
                    isSelected: selectedModel == model
                ) {
                    selectedModel = model
                    AppSettings.whisperModel = model
                    
                    // Trigger model reload in SpeechService
                    Task {
                        await SpeechService.shared.reloadModelIfNeeded()
                    }
                    
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isExpanded = false
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
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

/// Row for selecting Whisper model
private struct WhisperModelRow: View {
    let model: WhisperModel
    let isSelected: Bool
    let onSelect: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 16)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    Text(model.description)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.white.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - About Row

struct AboutRow: View {
    @State private var isHovered = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    var body: some View {
        Button {
            // Check for updates
            if let delegate = AppDelegate.shared {
                delegate.updater.checkForUpdates()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))
                    .frame(width: 16)

                Text("Check for Updates")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                Spacer()

                Text(appVersion)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Quit Row

struct QuitRow: View {
    @State private var isHovered: Bool = false

    var body: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(isHovered ? Color(red: 1.0, green: 0.4, blue: 0.4) : Color(red: 1.0, green: 0.4, blue: 0.4).opacity(0.7))
                    .frame(width: 16)

                Text("Quit")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isHovered ? Color(red: 1.0, green: 0.4, blue: 0.4) : Color(red: 1.0, green: 0.4, blue: 0.4).opacity(0.7))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Accessibility Permission Row

struct AccessibilityRow: View {
    let isEnabled: Bool

    @State private var isHovered = false
    @State private var refreshTrigger = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .frame(width: 16)

            Text("Accessibility")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)

            Spacer()

            if isEnabled {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)

                Text("On")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                Button(action: openAccessibilitySettings) {
                    Text("Enable")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTrigger.toggle()
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct MenuRow: View {
    let icon: String
    let label: String
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var textColor: Color {
        if isDestructive {
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
        return .white.opacity(isHovered ? 1.0 : 0.7)
    }
}

struct MenuToggleRow: View {
    let icon: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                Circle()
                    .fill(isOn ? TerminalColors.green : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text(isOn ? "On" : "Off")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}



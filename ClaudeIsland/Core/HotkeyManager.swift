//
//  HotkeyManager.swift
//  ClaudeIsland
//
//  Global hotkey detection and configuration
//

import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

/// Supported hotkey types
enum HotkeyType: Codable, Equatable {
    case doubleTapCommand
    case doubleTapOption
    case doubleTapControl
    case keyCombo(modifiers: Int, keyCode: Int)
    
    var displayName: String {
        switch self {
        case .doubleTapCommand:
            return "Double-tap Command"
        case .doubleTapOption:
            return "Double-tap Option"
        case .doubleTapControl:
            return "Double-tap Control"
        case .keyCombo(let modifiers, let keyCode):
            var parts: [String] = []
            let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
            if flags.contains(.control) { parts.append("^") }
            if flags.contains(.option) { parts.append("Option") }
            if flags.contains(.shift) { parts.append("Shift") }
            if flags.contains(.command) { parts.append("Cmd") }
            
            // Convert key code to character
            let keyChar = KeyCodeMapper.character(for: keyCode) ?? "?"
            parts.append(keyChar)
            
            return parts.joined(separator: "+")
        }
    }
    
    /// Common preset hotkeys
    static let presets: [HotkeyType] = [
        .doubleTapCommand,
        .doubleTapOption,
        .keyCombo(modifiers: Int(NSEvent.ModifierFlags.command.rawValue), keyCode: kVK_Space),
        .keyCombo(modifiers: Int(NSEvent.ModifierFlags.control.rawValue), keyCode: kVK_Space),
        .keyCombo(modifiers: Int(NSEvent.ModifierFlags.option.rawValue), keyCode: kVK_Space)
    ]
}

/// Maps key codes to displayable characters
enum KeyCodeMapper {
    static func character(for keyCode: Int) -> String? {
        switch keyCode {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Escape"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_M: return "M"
        default: return nil
        }
    }
}

/// Manages global hotkey detection
@MainActor
class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()
    
    // MARK: - Published State
    
    @Published var hotkey: HotkeyType {
        didSet {
            saveHotkey()
        }
    }
    
    // MARK: - Hotkey Activation
    
    let activated = PassthroughSubject<Void, Never>()
    
    // MARK: - Private State
    
    private var lastModifierPress: Date?
    private let doubleTapThreshold: TimeInterval = 0.3
    private var flagsMonitor: EventMonitor?
    private var keyMonitor: EventMonitor?
    private var lastModifierFlags: NSEvent.ModifierFlags = []
    
    // Track if modifier was pressed alone (no other keys)
    private var modifierPressedAlone = false
    
    // MARK: - Initialization
    
    private init() {
        // Load saved hotkey or use default
        if let data = UserDefaults.standard.data(forKey: "summonHotkey"),
           let saved = try? JSONDecoder().decode(HotkeyType.self, from: data) {
            self.hotkey = saved
        } else {
            self.hotkey = .doubleTapCommand
        }
        
        setupMonitors()
    }
    
    // MARK: - Setup
    
    private func setupMonitors() {
        // Monitor modifier key changes (for double-tap detection)
        flagsMonitor = EventMonitor(mask: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }
        flagsMonitor?.start()
        
        // Monitor key presses (for key combo detection)
        keyMonitor = EventMonitor(mask: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyDown(event)
            }
        }
        keyMonitor?.start()
    }
    
    // MARK: - Event Handling
    
    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        
        // Check for double-tap modifier hotkeys
        switch hotkey {
        case .doubleTapCommand:
            handleDoubleTapModifier(flags: flags, targetFlag: .command)
        case .doubleTapOption:
            handleDoubleTapModifier(flags: flags, targetFlag: .option)
        case .doubleTapControl:
            handleDoubleTapModifier(flags: flags, targetFlag: .control)
        case .keyCombo:
            // Key combos are handled in handleKeyDown
            break
        }
        
        lastModifierFlags = flags
    }
    
    private func handleDoubleTapModifier(flags: NSEvent.ModifierFlags, targetFlag: NSEvent.ModifierFlags) {
        let wasPressed = lastModifierFlags.contains(targetFlag)
        let isPressed = flags.contains(targetFlag)
        
        // Only the target modifier should be pressed (no other modifiers)
        let onlyTargetPressed = flags == targetFlag
        
        if !wasPressed && isPressed && onlyTargetPressed {
            // Modifier just pressed (alone)
            modifierPressedAlone = true
        } else if wasPressed && !isPressed && modifierPressedAlone {
            // Modifier just released after being pressed alone
            let now = Date()
            
            if let lastPress = lastModifierPress,
               now.timeIntervalSince(lastPress) < doubleTapThreshold {
                // Double-tap detected!
                activated.send(())
                lastModifierPress = nil
            } else {
                lastModifierPress = now
            }
            
            modifierPressedAlone = false
        } else if isPressed && !onlyTargetPressed {
            // Another key was pressed while modifier held - not a clean tap
            modifierPressedAlone = false
        }
    }
    
    private func handleKeyDown(_ event: NSEvent) {
        guard case .keyCombo(let modifiers, let keyCode) = hotkey else {
            return
        }
        
        let currentModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let targetModifiers = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        
        if currentModifiers == targetModifiers && Int(event.keyCode) == keyCode {
            activated.send(())
        }
    }
    
    // MARK: - Persistence
    
    private func saveHotkey() {
        if let data = try? JSONEncoder().encode(hotkey) {
            UserDefaults.standard.set(data, forKey: "summonHotkey")
        }
    }
}

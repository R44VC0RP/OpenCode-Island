//
//  AccessibilityModifiers.swift
//  OpenCodeIsland
//
//  Accessibility extensions and modifiers for VoiceOver support.
//

import SwiftUI

extension View {
    func accessibleButton(label: String, hint: String? = nil) -> some View {
        self
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
            .accessibilityAddTraits(.isButton)
    }
    
    func accessibleTextField(label: String, value: String) -> some View {
        self
            .accessibilityLabel(label)
            .accessibilityValue(value.isEmpty ? "Empty" : value)
    }
    
    func accessibleStatus(label: String, value: String) -> some View {
        self
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAddTraits(.updatesFrequently)
    }
    
    func accessibleSection(label: String) -> some View {
        self
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
    }
    
    @ViewBuilder
    func reduceMotionAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            self.animation(nil, value: value)
        } else {
            self.animation(animation, value: value)
        }
    }
}

struct AccessibilityAnnouncement {
    static func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high
        ])
    }
}

extension View {
    func keyboardNavigable(onUp: (() -> Void)? = nil, onDown: (() -> Void)? = nil, onEnter: (() -> Void)? = nil, onEscape: (() -> Void)? = nil) -> some View {
        self.onKeyPress(keys: [.upArrow, .downArrow, .return, .escape]) { press in
            switch press.key {
            case .upArrow:
                onUp?()
                return .handled
            case .downArrow:
                onDown?()
                return .handled
            case .return:
                onEnter?()
                return .handled
            case .escape:
                onEscape?()
                return .handled
            default:
                return .ignored
            }
        }
    }
    
    func focusableRow(isFocused: Bool) -> some View {
        self
            .focusable()
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
            )
    }
}

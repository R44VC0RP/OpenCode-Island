# AGENTS.md - OpenCode Island

> Guidelines for AI agents working in this codebase

## Project Overview

OpenCode Island is a native macOS menu bar app (Swift/SwiftUI) that provides a Dynamic Island-style interface for interacting with OpenCode. Users summon the island with a customizable hotkey, type prompts (optionally selecting an agent with `/`), and receive results when processing completes.

## Build Commands

```bash
# Development build (via Xcode)
xcodebuild -scheme ClaudeIsland -configuration Debug build

# Build without code signing (for testing)
xcodebuild -scheme ClaudeIsland -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO

# Release archive build
./scripts/build.sh
```

**Build Requirements:**
- macOS 15.6+ (Sequoia)
- Xcode with Swift 5.0+
- Apple Developer ID certificate (for release builds)

## Testing

**No test suite currently exists.** Add tests via Xcode (File > New > Target > Unit Testing Bundle).

## Dependencies

Managed via Swift Package Manager (integrated with Xcode):
- `swift-markdown` (0.5.0+) - Markdown rendering
- `Sparkle` (2.0.0+) - Auto-update framework
- `mixpanel-swift` (master) - Analytics

## Architecture

### Core User Flow

```
1. User presses hotkey (e.g., double-tap Cmd)
2. Island pops down with focused text input
3. User types prompt (can use /AgentName to select agent)
4. User presses Enter to submit
5. Island shows processing state
6. After completion, island shows result
7. User dismisses or it auto-collapses
```

### Key Files

| File | Purpose |
|------|---------|
| `Core/HotkeyManager.swift` | Global hotkey detection (double-tap, key combos) |
| `Core/NotchViewModel.swift` | Main state machine for prompt/processing/result states |
| `Models/Agent.swift` | Agent model with built-in agents (General, Docs, Research) |
| `Models/PromptSession.swift` | Current prompt, agent, and result tracking |
| `UI/Views/NotchView.swift` | Main SwiftUI view with prompt input, processing, result |
| `UI/Views/NotchMenuView.swift` | Settings menu with hotkey picker |

### File Structure

```
ClaudeIsland/
  App/              # App lifecycle, delegates
  Core/             # HotkeyManager, NotchViewModel, geometry
  Events/           # EventMonitor for keyboard/mouse events
  Models/           # Agent, PromptSession
  Services/Update/  # Sparkle auto-update driver
  UI/
    Components/     # ProcessingSpinner, MarkdownRenderer, etc.
    Views/          # NotchView, NotchMenuView
    Window/         # NotchWindow, NotchWindowController
```

## Code Style Guidelines

### File Header

```swift
//
//  FileName.swift
//  ClaudeIsland
//
//  Brief description
//

import Foundation
```

### Import Order

1. Foundation/Swift standard library
2. Apple frameworks (AppKit, Combine, SwiftUI)
3. Third-party packages

### Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Types/Classes | PascalCase | `HotkeyManager`, `NotchViewModel` |
| Properties/Methods | camelCase | `promptText`, `submitPrompt()` |
| Booleans | `is`/`has`/`can` prefix | `isInputFocused`, `showAgentPicker` |
| Enums | PascalCase type, camelCase cases | `enum NotchStatus { case closed, opened }` |

### Concurrency Patterns

- `@MainActor` for UI-related classes
- `Task` for async work
- Combine for reactive state (`@Published`, `PassthroughSubject`)

### SwiftUI Patterns

```swift
struct MyView: View {
    @ObservedObject var viewModel: NotchViewModel
    @FocusState private var isInputFocused: Bool
    
    var body: some View { ... }
    
    // MARK: - Subviews
    @ViewBuilder
    private var headerRow: some View { ... }
}
```

## Critical: Panel Sizing and Hit Testing

**When adding UI elements to the settings menu or any panel content, you MUST update the `openedSize` in `NotchViewModel.swift`.**

### Why This Matters

The app uses a custom hit testing system to determine which clicks should be handled by the panel vs. passed through to windows behind. The click detection bounds are calculated from `openedSize`, with some adjustments in `NotchGeometry.openedScreenRect()`.

If UI content extends beyond the calculated bounds:
1. Clicks on those elements will be detected as "outside" the panel
2. The global mouse handler (`handleMouseDown`) will immediately close the panel
3. The SwiftUI button never receives the `mouseUp` event, so the action never fires
4. **Buttons will appear to do nothing** even though they render correctly

### How to Fix

When adding rows/content to `NotchMenuView.swift` or other panel views:

1. **Calculate the total content height** - sum up all rows (~44px each), dividers (~8px), and padding
2. **Update `openedSize`** in `NotchViewModel.swift`:
```swift
case .menu:
    return CGSize(
        width: min(screenRect.width * 0.4, 480),
        height: 700  // Must accommodate ALL menu items
    )
```

3. **Test by clicking elements at the bottom** of the panel - these are most likely to fall outside bounds

### Related Files

| File | Role in Hit Testing |
|------|---------------------|
| `Core/NotchViewModel.swift` | `openedSize` defines panel dimensions per content type |
| `Core/NotchGeometry.swift` | `openedScreenRect()` calculates click detection bounds |
| `UI/Window/NotchViewController.swift` | `hitTestRect()` uses geometry to filter clicks |
| `UI/Window/NotchWindow.swift` | `sendEvent()` routes or passes through mouse events |

## Common Tasks

### Adding a New Agent

1. Add to `Agent.builtIn` in `Models/Agent.swift`:
```swift
Agent(id: "my-agent", name: "MyAgent", description: "Does X", icon: "sparkles")
```

### Modifying the Hotkey System

- Hotkey types: `Core/HotkeyManager.swift` - `HotkeyType` enum
- Detection logic: `handleFlagsChanged()`, `handleDoubleTapModifier()`
- Presets: `HotkeyType.presets` array

### Adding a New Content State

1. Add case to `NotchContentType` in `Core/NotchViewModel.swift`
2. Update `openedSize` computed property for sizing
3. Add view case in `NotchView.contentView`

### Adding Menu Items to Settings

1. Add your row component to `NotchMenuView.swift`
2. **CRITICAL:** Update the menu height in `NotchViewModel.openedSize`:
```swift
case .menu:
    return CGSize(
        width: min(screenRect.width * 0.4, 480),
        height: 700  // Increase if adding more rows!
    )
```
3. Test that buttons at the bottom of the menu still work

### Connecting to OpenCode (Future)

The `submitPrompt()` method in `NotchViewModel` currently runs a mock timer. Replace with actual OpenCode integration:

```swift
func submitPrompt() {
    // Create session
    let session = PromptSession(prompt: text, agent: selectedAgent)
    currentSession = session
    contentType = .processing
    
    // TODO: Replace mock with OpenCode call
    Task {
        let result = await OpenCodeBridge.shared.execute(
            prompt: text,
            agent: selectedAgent
        )
        await MainActor.run {
            self.resultText = result
            self.contentType = .result
        }
    }
}
```

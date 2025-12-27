//
//  NotchViewController.swift
//  ClaudeIsland
//
//  Hosts the SwiftUI NotchView in AppKit with click-through support
//

import AppKit
import SwiftUI

/// Custom NSHostingView that only accepts mouse events within the panel bounds.
/// Clicks outside the panel pass through to windows behind.
class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var hitTestRect: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only accept hits within the panel rect
        guard hitTestRect().contains(point) else {
            return nil  // Pass through to windows behind
        }
        return super.hitTest(point)
    }
}

class NotchViewController: NSViewController {
    private let viewModel: NotchViewModel
    private var hostingView: PassThroughHostingView<NotchView>!

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        hostingView = PassThroughHostingView(rootView: NotchView(viewModel: viewModel))

        // Calculate the hit-test rect based on panel state
        hostingView.hitTestRect = { [weak self] in
            guard let self = self else { return .zero }
            let vm = self.viewModel
            let geometry = vm.geometry

            // Window coordinates: origin at bottom-left, Y increases upward
            // The window is positioned at top of screen, so panel is at top of window
            let windowHeight = geometry.windowHeight

            switch vm.status {
            case .opened:
                let panelSize = vm.openedSize
                // Panel is centered horizontally, anchored to top
                let panelWidth = panelSize.width + 80  // Extra padding for safety
                let panelHeight = panelSize.height + 50  // Extra padding to ensure bottom buttons are included
                let screenWidth = geometry.screenRect.width
                let rect = CGRect(
                    x: (screenWidth - panelWidth) / 2,
                    y: windowHeight - panelHeight,
                    width: panelWidth,
                    height: panelHeight
                )
                // Debug: uncomment to see hit rect
                // print("📐 HitTest rect: \(rect), panelSize: \(panelSize)")
                return rect
            case .closed, .popping:
                // When closed, check if processing - need larger area for compact indicator
                if vm.contentType == .processing {
                    let notchRect = geometry.deviceNotchRect
                    let screenWidth = geometry.screenRect.width
                    // Larger area for processing indicator
                    return CGRect(
                        x: (screenWidth - notchRect.width) / 2 - 60,
                        y: windowHeight - notchRect.height - 60,
                        width: notchRect.width + 120,
                        height: notchRect.height + 70
                    )
                }
                // When closed, use the notch rect
                let notchRect = geometry.deviceNotchRect
                let screenWidth = geometry.screenRect.width
                // Add some padding for easier interaction
                return CGRect(
                    x: (screenWidth - notchRect.width) / 2 - 10,
                    y: windowHeight - notchRect.height - 5,
                    width: notchRect.width + 20,
                    height: notchRect.height + 10
                )
            }
        }

        self.view = hostingView
    }
}

//
//  NotchGeometry.swift
//  OpenCodeIsland
//
//  Geometry calculations for the notch
//

import CoreGraphics
import Foundation

struct HitTestPadding {
    let horizontal: CGFloat
    let vertical: CGFloat
    
    static let openedPanel = HitTestPadding(horizontal: 40, vertical: 25)
    static let closedNotch = HitTestPadding(horizontal: 10, vertical: 5)
    static let processingIndicator = HitTestPadding(horizontal: 60, vertical: 35)
}

struct NotchGeometry: Sendable {
    let deviceNotchRect: CGRect
    let screenRect: CGRect
    let windowHeight: CGFloat

    /// The notch rect in screen coordinates (for hit testing with global mouse position)
    var notchScreenRect: CGRect {
        CGRect(
            x: screenRect.midX - deviceNotchRect.width / 2,
            y: screenRect.maxY - deviceNotchRect.height,
            width: deviceNotchRect.width,
            height: deviceNotchRect.height
        )
    }

    /// The opened panel rect in screen coordinates for a given size
    func openedScreenRect(for size: CGSize) -> CGRect {
        // Match the actual rendered panel size (tuned to match visual output)
        let width = size.width - 6
        let height = size.height - 30
        return CGRect(
            x: screenRect.midX - width / 2,
            y: screenRect.maxY - height,
            width: width,
            height: height
        )
    }

    /// Check if a point is in the notch area (with padding for easier interaction)
    func isPointInNotch(_ point: CGPoint) -> Bool {
        notchScreenRect.insetBy(dx: -10, dy: -5).contains(point)
    }

    /// Check if a point is in the opened panel area
    func isPointInOpenedPanel(_ point: CGPoint, size: CGSize) -> Bool {
        openedScreenRect(for: size).contains(point)
    }

    /// Check if a point is outside the opened panel (for closing)
    func isPointOutsidePanel(_ point: CGPoint, size: CGSize) -> Bool {
        !openedScreenRect(for: size).contains(point)
    }
    
    // MARK: - Hit Test Rects (Window Coordinates)
    
    func hitTestRectForOpenedPanel(size: CGSize, padding: HitTestPadding = .openedPanel) -> CGRect {
        let panelWidth = size.width + (padding.horizontal * 2)
        let panelHeight = size.height + (padding.vertical * 2)
        return CGRect(
            x: (screenRect.width - panelWidth) / 2,
            y: windowHeight - panelHeight,
            width: panelWidth,
            height: panelHeight
        )
    }
    
    func hitTestRectForClosedNotch(padding: HitTestPadding = .closedNotch) -> CGRect {
        CGRect(
            x: (screenRect.width - deviceNotchRect.width) / 2 - padding.horizontal,
            y: windowHeight - deviceNotchRect.height - padding.vertical,
            width: deviceNotchRect.width + (padding.horizontal * 2),
            height: deviceNotchRect.height + (padding.vertical * 2)
        )
    }
    
    func hitTestRectForProcessingIndicator() -> CGRect {
        hitTestRectForClosedNotch(padding: .processingIndicator)
    }
}

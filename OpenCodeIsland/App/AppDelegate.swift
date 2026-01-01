//
//  AppDelegate.swift
//  OpenCodeIsland
//
//  App delegate for OpenCode Island
//

import AppKit
import IOKit
import Mixpanel
import Sparkle
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private var updateCheckTimer: Timer?
    private let startupCoordinator = StartupCoordinator.shared

    static var shared: AppDelegate?
    let updater: SPUUpdater
    private let userDriver: NotchUserDriver

    var windowController: NotchWindowController? {
        windowManager?.windowController
    }

    override init() {
        userDriver = NotchUserDriver()
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: nil
        )
        super.init()
        AppDelegate.shared = self

        do {
            try updater.start()
        } catch {
            print("Failed to start Sparkle updater: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        // Initialize analytics
        Mixpanel.initialize(token: "49814c1436104ed108f3fc4735228496")

        let distinctId = getOrCreateDistinctId()
        Mixpanel.mainInstance().identify(distinctId: distinctId)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = Foundation.ProcessInfo.processInfo.operatingSystemVersionString

        Mixpanel.mainInstance().registerSuperProperties([
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        Mixpanel.mainInstance().people.set(properties: [
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        Mixpanel.mainInstance().track(event: "App Launched")
        Mixpanel.mainInstance().flush()

        // Set as accessory app (no dock icon)
        NSApplication.shared.setActivationPolicy(.accessory)

        _ = HotkeyManager.shared
        
        Task {
            await performCoordinatedStartup()
        }

        setupUpdateChecker()
    }
    
    private func performCoordinatedStartup() async {
        let success = await startupCoordinator.performStartup()
        
        if success {
            windowManager = WindowManager()
            if let controller = windowManager?.setupNotchWindow() {
                Task {
                    await controller.viewModel.connectToServer()
                }
            }
            
            screenObserver = ScreenObserver { [weak self] in
                self?.handleScreenChange()
            }
        } else {
            handleStartupFailure()
        }
    }
    
    private func handleStartupFailure() {
        guard case .failed(let error) = startupCoordinator.phase else { return }
        
        let alert = NSAlert()
        alert.messageText = "Failed to Start OpenCode"
        alert.informativeText = error.userMessage
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .critical
        
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                await performCoordinatedStartup()
            }
        } else {
            NSApp.terminate(nil)
        }
    }
    
    private func setupUpdateChecker() {
        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        }

        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let updater = self?.updater, updater.canCheckForUpdates else { return }
            updater.checkForUpdates()
        }
    }

    private func handleScreenChange() {
        _ = windowManager?.setupNotchWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the OpenCode server if we started it
        OpenCodeServerManager.shared.stopServer()
        
        Mixpanel.mainInstance().flush()
        updateCheckTimer?.invalidate()
        screenObserver = nil
    }

    private func getOrCreateDistinctId() -> String {
        let key = "mixpanel_distinct_id"

        if let existingId = UserDefaults.standard.string(forKey: key) {
            return existingId
        }

        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        if let uuid = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            UserDefaults.standard.set(uuid, forKey: key)
            return uuid
        }

        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.opencode.island"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }
}

//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    /// v15p3fz (2026-05-17): notch-mode pill manager. Only instantiated
    /// when `clicky.useNotch` is true — otherwise the classic menu-bar
    /// panel is used. Ship 1 picks at launch only (no hot-swap).
    private var notchPanelManager: NotchPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        // v15p3gm (2026-05-17): menu bar icon ALWAYS active so the
        // classic dropdown keeps working as a known-good fallback while
        // the notch is being redesigned. The notch pill is an additive
        // surface when enabled — it doesn't replace the menu bar icon
        // anymore. This means the user can always reach Quit, settings,
        // and the "Notch mode" toggle via the menu bar icon, even if
        // the notch UI is mid-redesign and broken.
        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        let useNotch = UserDefaults.standard.bool(forKey: "clicky.useNotch")
        if useNotch {
            notchPanelManager = NotchPanelManager(companionManager: companionManager)
            print("🎯 Clicky: notch mode enabled (pill + menu bar icon both active)")
        }
        companionManager.start()

        // v15p3cy (2026-05-15): eager-touch the sound engine so its
        // custom sounds folder gets created on first launch (and any
        // sample files already present are loaded), even if the user
        // never opens the panel. Lazy init would otherwise defer this
        // until first panel render or first wired-event play() call.
        _ = ClickySoundEngine.shared
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        // v15p3fz: also covers notch mode — same trigger condition, just
        // expand the notch panel instead of dropping the menu-bar panel.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
            if let notchPanelManager {
                // Small delay so the pill has time to position itself.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    notchPanelManager.showPill()
                }
            }
        }
        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
        // v16pv (2026-06-06): kill the on-device LLM server we spawned.
        LocalLLMManager.shared.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Clicky: Registered as login item")
            } catch {
                print("⚠️ Clicky: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Clicky: Sparkle updater failed to start: \(error)")
        }
    }
}

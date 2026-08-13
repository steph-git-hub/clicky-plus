//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SQLite3
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
        // v16r17 (2026-08-05): single-instance guard. MUST run before
        // anything else starts — see the comment on the method.
        terminateOtherInstances()

        // v16r27 (2026-08-13): purge CFNetwork's per-app Alt-Svc cache
        // before the voice pipelines open any connections — see the
        // comment on the method for why.
        purgeAltServicesCache()

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

    /// v16r17 (2026-08-05): terminate any OTHER running Clicky instance
    /// so the newest launch always wins.
    ///
    /// WHY. Clicky registers itself as a login item, so an instance is
    /// almost always already running. Hitting Run in Xcode only kills the
    /// instance Xcode itself launched — a login-item copy survives, and
    /// macOS keeps its already-mapped binary image even after the build
    /// replaces the file on disk. Result: two Clickys, one silently
    /// serving PRE-BUILD code, and whichever owns the realtime session
    /// answers Marin's tool calls.
    ///
    /// Live cost 2026-08-05: a stale instance served `memory` calls after
    /// a fresh build. `forget` worked (old code had it) but `undo_last`
    /// hit the old `default:` branch, so a correct new feature looked
    /// broken — "she undid it, but said she couldn't find anything to
    /// undo" — and the capture journal never got written. Cost a full
    /// debugging cycle chasing a bug that did not exist.
    ///
    /// Newest-wins is the right rule: the instance that just launched is
    /// the one the user (or Xcode) deliberately started. Runs FIRST in
    /// applicationDidFinishLaunching so the old process finishes its
    /// cleanup — `companionManager.stop()`, `LocalLLMManager.stop()` —
    /// before this one claims the hotkey tap and spawns its LLM server.
    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        guard !others.isEmpty else { return }

        for app in others {
            print("🎯 Clicky: terminating stale instance (pid \(app.processIdentifier))")
            app.terminate()
        }

        // Bounded wait so the old instance releases the CGEvent tap and
        // its LLM server port before we start ours. Escalate to a force
        // kill rather than hang the launch on a wedged process.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, others.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        for app in others where !app.isTerminated {
            print("⚠️ Clicky: stale instance (pid \(app.processIdentifier)) ignored quit — forcing")
            app.forceTerminate()
        }
    }

    /// v16r27 (2026-08-13): clear CFNetwork's per-app Alt-Svc cache at
    /// launch.
    ///
    /// WHY. Root cause of the 2026-08-12 total outage: the router mangles
    /// UDP, HTTP/3/QUIC silently dies, but CFNetwork's per-app Alt-Svc
    /// store (~/Library/HTTPStorages/<bundle-id>/httpstorages.sqlite,
    /// alt_services table) keeps steering every request onto broken h3 —
    /// an app-only network death that survives reboot. The store was
    /// cleared manually on 8/12 and the app RE-LEARNED h3 steering for
    /// all three critical hosts (worker proxy, generativelanguage,
    /// ElevenLabs) within a day — observed again 2026-08-13, alongside
    /// polish timeouts and Gemini socket deaths. Clearing at launch
    /// bounds the damage to one app session instead of persisting
    /// indefinitely. Fresh Alt-Svc hints are re-learned per run; if the
    /// network is healthy, h3 works and nothing is lost — the cache
    /// only ever saves one upgrade round-trip per host.
    private func purgeAltServicesCache() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let dbPath = NSString(
            string: "~/Library/HTTPStorages/\(bundleID)/httpstorages.sqlite"
        ).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            print("⚠️ Clicky: could not open HTTPStorages db to clear Alt-Svc cache")
            return
        }
        defer { sqlite3_close(db) }
        if sqlite3_exec(db, "DELETE FROM alt_services;", nil, nil, nil) == SQLITE_OK {
            let cleared = sqlite3_changes(db)
            if cleared > 0 {
                print("🌐 Clicky: cleared \(cleared) Alt-Svc entr\(cleared == 1 ? "y" : "ies") (h3 steering) at launch")
            }
        } else {
            print("⚠️ Clicky: Alt-Svc cache clear failed: \(String(cString: sqlite3_errmsg(db)))")
        }
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

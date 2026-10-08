import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var previewWindow: NSWindow?
    private var wakeObserver: NSObjectProtocol?

    /// Ask the shared SSH master to exit so quitting does not leave an
    /// authenticated connection parked for its eight-hour persist window.
    func applicationWillTerminate(_ notification: Notification) {
        let defaults = UserDefaults.standard
        let source = ClusterSourceResolution.source(
            kind: defaults.string(forKey: "dataSourceKind") ?? ClusterSourceKind.statusPage.rawValue,
            url: defaults.string(forKey: "statusPageURL") ?? ClusterSourceDefaults.statusPageURL,
            host: defaults.string(forKey: "sshHost") ?? ""
        )
        if let host = source.sshHost, !host.isEmpty {
            SSHMuxTeardown.exitMaster(host: host)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CityRenderHarness.runIfRequested() {
            NSApp.terminate(nil)
            return
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            let defaults = UserDefaults.standard
            let source = ClusterSourceResolution.source(
                kind: defaults.string(forKey: "dataSourceKind") ?? ClusterSourceKind.statusPage.rawValue,
                url: defaults.string(forKey: "statusPageURL") ?? ClusterSourceDefaults.statusPageURL,
                host: defaults.string(forKey: "sshHost") ?? ""
            )
            Task { @MainActor in
                await ClusterStore.shared.refreshAfterWake(source: source)
            }
        }

        guard ProcessInfo.processInfo.arguments.contains("--preview") else { return }

        let controller = NSHostingController(
            rootView: MenuBarPanel(store: .shared)
                .frame(width: 460, height: 600)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Colby GPU Cluster Preview"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 600))
        window.center()
        window.makeKeyAndOrderFront(nil)
        previewWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ColbyGPUClusterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ClusterStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(store: store)
        } label: {
            MenuBarStatusLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            AppSettingsView()
        }
    }
}

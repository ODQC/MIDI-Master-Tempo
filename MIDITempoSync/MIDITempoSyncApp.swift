import SwiftUI
import AppKit

@main
struct MIDITempoSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sync = SyncController()

    var body: some Scene {
        Window("MIDI Master Tempo", id: "main") {
            ContentView()
                .environmentObject(sync)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    // Don't leave the slaves playing when the app quits.
                    if sync.isRunning { sync.stop() }
                }
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

import AppKit
import SwiftUI

/// The entry point: one setup window, driven by one AppModel.
///
/// The model is a @StateObject owned by the App, so SwiftUI creates it once
/// and keeps it for the app's whole life. That is the SINGLE SOURCE OF TRUTH
/// for state: the setup view reads and edits it, and playback is started from
/// it, so nothing holds a second copy that could disagree.
///
/// `Window` (not `WindowGroup`) because there is exactly one setup window: a
/// WindowGroup would let ⌘N open a second one editing the same show.
@main
struct TableauXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window(AppModel.setupTitle, id: "setup") {
            SetupView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

/// The few things SwiftUI's App doesn't cover.
///
/// Built with `swift build`, this is a bare executable, not a `.app` bundle,
/// and macOS starts such a process as a background tool: no Dock icon, no menu
/// bar, and it never becomes the ACTIVE APP, so its windows can't take the
/// keyboard (Space and Esc would never arrive). Setting the activation policy
/// to `.regular` makes it a normal foreground app. A bundled build gets this
/// from its Info.plist; doing it in code makes both behave the same.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Closing the setup window ends the app. During playback the setup window
    // is hidden (ordered out), not closed, so this doesn't fire mid-show.
    //
    // [claude] AppKit also counts HIDING the last visible window (orderOut) as
    // closing it, which is how the first version quit on Play. Playback keeps
    // a window visible at every moment of the hand-over; see Playback.init.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

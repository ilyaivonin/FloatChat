import AppKit
import SwiftUI

@main
enum FloatChatMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        KeepAlive.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

private enum KeepAlive {
    static var delegate: AppDelegate?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let state = AppState()
    private var window: NSWindow?
    private var optionPasteMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowSupport.applyAppearance(lightMode: state.lightMode)
        AppMenu.install(appName: state.displayName)
        installOptionPasteMonitor()

        let root = ChatView()
            .environmentObject(state)
            .frame(minWidth: 280, minHeight: 380)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 348, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "FloatChat"
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.delegate = self
        WindowSupport.configure(
            window,
            alwaysOnTop: state.alwaysOnTop,
            title: state.displayName,
            opacity: state.opacity
        )
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        state.startServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let optionPasteMonitor {
            NSEvent.removeMonitor(optionPasteMonitor)
        }
        state.stopServer()
        LlamaRuntime.server.stop()
    }

    func windowWillClose(_ notification: Notification) {
        state.stopServer()
    }

    /// Option+V pastes in any text field of the app, in addition to the standard Command+V.
    private func installOptionPasteMonitor() {
        optionPasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags
                .intersection([.command, .option, .control, .shift, .capsLock])
                .subtracting(.capsLock)
            let isPaste = flags == .option
                && event.charactersIgnoringModifiers?.lowercased() == "v"
            guard isPaste else { return event }

            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            return nil
        }
    }
}

import AppKit
import SwiftUI

enum WindowSupport {
    static let settingsWindowID = NSUserInterfaceItemIdentifier("floatchat.settings")
    static let lightModeKey = "floatchat.lightMode"

    static func applyAppearance(lightMode: Bool) {
        NSApp.appearance = NSAppearance(named: lightMode ? .aqua : .darkAqua)
    }

    static func configure(_ window: NSWindow, alwaysOnTop: Bool, title: String, opacity: Double) {
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 280, height: 380)
        window.tabbingMode = .disallowed
        window.hidesOnDeactivate = false
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.alphaValue = clampedOpacity(opacity)
        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
        applyAlwaysOnTop(alwaysOnTop, window: window)
    }

    static func applyAlwaysOnTop(_ enabled: Bool, window: NSWindow? = nil) {
        for item in targetWindows(window) {
            item.level = enabled ? .floating : .normal
            item.hidesOnDeactivate = false
        }
    }

    static func applyOpacity(_ opacity: Double, window: NSWindow? = nil) {
        for item in targetWindows(window) where item.identifier != settingsWindowID {
            item.alphaValue = clampedOpacity(opacity)
        }
    }

    static func applyTitle(_ title: String, window: NSWindow? = nil) {
        for item in targetWindows(window) {
            item.title = title
        }
    }

    private static func clampedOpacity(_ value: Double) -> Double {
        min(max(value, 0.3), 1.0)
    }

    /// Main app windows only: sheets, panels and popovers keep their own opacity.
    private static func targetWindows(_ window: NSWindow?) -> [NSWindow] {
        if let window {
            return [window]
        }
        return NSApp.windows.filter { candidate in
            candidate.isVisible
                && candidate.sheetParent == nil
                && !(candidate is NSPanel)
        }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    var alwaysOnTop: Bool
    var title: String
    var opacity: Double

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                WindowSupport.configure(window, alwaysOnTop: alwaysOnTop, title: title, opacity: opacity)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                WindowSupport.configure(window, alwaysOnTop: alwaysOnTop, title: title, opacity: opacity)
            }
        }
    }
}

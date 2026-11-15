import SwiftUI
import AppKit

public final class AppSettingsWindowController: NSObject, NSWindowDelegate {
    public static let shared = AppSettingsWindowController()
    
    private var window: NSWindow?
    
    private override init() { super.init() }
    
    public func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Notchy"
        win.minSize = NSSize(width: 480, height: 420)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .vibrantDark)
        win.backgroundColor = NSColor(white: 0.07, alpha: 1.0)
        win.delegate = self
        win.center()
        win.contentView = NSHostingView(rootView: AppSettingsView().padding(.top, 6))
        
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

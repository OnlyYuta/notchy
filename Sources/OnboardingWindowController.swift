import SwiftUI
import AppKit

public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    public static let shared = OnboardingWindowController()
    
    private var window: NSWindow?
    
    private override init() {
        super.init()
    }
    
    public func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let rect = NSRect(x: 0, y: 0, width: 580, height: 720)
        let newWindow = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        newWindow.title = "Notchy"
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.isMovableByWindowBackground = true
        newWindow.isReleasedWhenClosed = false
        newWindow.backgroundColor = .clear
        newWindow.appearance = NSAppearance(named: .vibrantDark)
        newWindow.delegate = self
        newWindow.level = .floating
        newWindow.center()
        
        let contentView = OnboardingView { [weak self] in
            self?.close()
        }
        let hosting = NSHostingView(rootView: contentView)
        newWindow.contentView = hosting
        
        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    public func close() {
        window?.orderOut(nil)
        window = nil
        NotchWindowController.shared.playIntro()
    }
    
    public func windowWillClose(_ notification: Notification) {
        window = nil
        // Closing the window with the red button must not leave the notch hidden
        NotchWindowController.shared.playIntro()
    }
}

import AppKit
import Combine

public struct NotchInfo: Equatable {
    public let hasPhysicalNotch: Bool
    public let isExternalDisplay: Bool
    public let screenFrame: CGRect
    public let notchRect: CGRect
    public let notchSize: CGSize
    public let screen: NSScreen
    
    public static func == (lhs: NotchInfo, rhs: NotchInfo) -> Bool {
        lhs.hasPhysicalNotch == rhs.hasPhysicalNotch &&
        lhs.isExternalDisplay == rhs.isExternalDisplay &&
        lhs.screenFrame == rhs.screenFrame &&
        lhs.notchRect == rhs.notchRect &&
        lhs.notchSize == rhs.notchSize &&
        lhs.screen == rhs.screen
    }
}

public final class NotchManager: ObservableObject {
    public static let shared = NotchManager()
    
    @Published public private(set) var currentNotch: NotchInfo
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        self.currentNotch = NotchManager.detectNotch(preferredScreen: NotchManager.chosenScreen())
        setupNotificationObserver()
        SettingsService.shared.$notchDisplayID
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }
    
    private func setupNotificationObserver() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }
    
    public func refresh() {
        let screens = NSScreen.screens
        let targetScreen = NotchManager.chosenScreen() ?? screens.first
        let detected = NotchManager.detectNotch(preferredScreen: targetScreen)
        if detected != self.currentNotch {
            self.currentNotch = detected
        }
    }
    
    public func updateScreen(_ screen: NSScreen) {
        let newInfo = NotchManager.notchInfo(for: screen)
        if newInfo != self.currentNotch {
            self.currentNotch = newInfo
        }
    }
    
    /// The notch stays on its monitor; moving the cursor to another display does not drag it along.
    public func updateScreenForMouseLocation(_ point: NSPoint) {}
    
    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
    
    /// The monitor picked in settings; "auto" (or a disconnected one) means the built-in display, else the main one.
    public static func chosenScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let id = SettingsService.shared.notchDisplayID
        if id != "auto", let match = screens.first(where: { displayID(of: $0).map(String.init) == id }) { return match }
        return screens.first { displayID(of: $0).map { CGDisplayIsBuiltin($0) != 0 } ?? false } ?? NSScreen.main ?? screens.first
    }
    
    public static func isExternal(screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            if let left = screen.auxiliaryTopLeftArea, left.width > 0 {
                return false
            }
        }
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return CGDisplayIsBuiltin(screenNumber) == 0
        }
        return false
    }
    
    public static func notchInfo(for screen: NSScreen) -> NotchInfo {
        let external = isExternal(screen: screen)
        
        if #available(macOS 12.0, *),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           left.width > 0, right.width > 0,
           right.minX > left.maxX {
            
            let notchWidth = right.minX - left.maxX
            let notchHeight = max(screen.safeAreaInsets.top, screen.frame.height - left.minY)
            let notchX = screen.frame.origin.x + left.maxX
            let notchY = screen.frame.maxY - notchHeight
            let rect = CGRect(x: notchX, y: notchY, width: notchWidth, height: notchHeight)
            
            return NotchInfo(
                hasPhysicalNotch: true,
                isExternalDisplay: false,
                screenFrame: screen.frame,
                notchRect: rect,
                notchSize: CGSize(width: notchWidth, height: notchHeight),
                screen: screen
            )
        }
        
        // Displays without a hardware notch (external displays or non-notch Macs)
        let defaultWidth: CGFloat = 185.0
        let defaultHeight: CGFloat = 32.0
        let notchX = screen.frame.midX - (defaultWidth / 2.0)
        let notchY = screen.frame.maxY - defaultHeight
        let rect = CGRect(x: notchX, y: notchY, width: defaultWidth, height: defaultHeight)
        
        return NotchInfo(
            hasPhysicalNotch: false,
            isExternalDisplay: external,
            screenFrame: screen.frame,
            notchRect: rect,
            notchSize: CGSize(width: defaultWidth, height: defaultHeight),
            screen: screen
        )
    }
    
    public static func detectNotch(preferredScreen: NSScreen? = nil) -> NotchInfo {
        let screens = NSScreen.screens
        
        if let screen = preferredScreen, screens.contains(screen) {
            return notchInfo(for: screen)
        }
        
        // Find a screen with physical notch first
        for screen in screens {
            if #available(macOS 12.0, *) {
                if let left = screen.auxiliaryTopLeftArea,
                   let right = screen.auxiliaryTopRightArea,
                   left.width > 0, right.width > 0,
                   right.minX > left.maxX {
                    return notchInfo(for: screen)
                }
            }
        }
        
        // Fallback for displays without a hardware notch
        let targetScreen = NSScreen.main ?? screens.first ?? NSScreen()
        return notchInfo(for: targetScreen)
    }
}

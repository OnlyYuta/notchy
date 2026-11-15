import Foundation
import AppKit
import ApplicationServices
import UserNotifications
import CoreGraphics
import Combine
import AVFoundation

public final class PermissionManager: ObservableObject {
    public static let shared = PermissionManager()
    
    @Published public private(set) var isAccessibilityGranted: Bool = false
    @Published public private(set) var isNotificationsGranted: Bool = false
    @Published public private(set) var isScreenCaptureGranted: Bool = false
    @Published public private(set) var isMicrophoneGranted: Bool = false
    @Published public private(set) var isInstalledInApplications: Bool = false
    
    private var pollTimer: Timer?
    
    private init() {
        checkAppLocation()
        checkAllPermissions()
    }
    
    deinit {
        stopPolling()
    }
    
    public var isAllRequiredGranted: Bool {
        isAccessibilityGranted
    }
    
    public func checkAppLocation() {
        let path = Bundle.main.bundlePath
        let inApps = path.hasPrefix("/Applications") || path.hasPrefix("/System/Applications") || path.contains("/Applications/")
        if self.isInstalledInApplications != inApps {
            DispatchQueue.main.async {
                self.isInstalledInApplications = inApps
            }
        }
    }
    
    // MARK: - Polling for Real-Time UI Updates
    
    public func startPolling() {
        stopPolling()
        checkAppLocation()
        checkAllPermissions()
        // Poll every 0.5s while onboarding or permission UI is open
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkAllPermissions()
        }
    }
    
    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
    
    // MARK: - Permission Checks
    
    public func checkAllPermissions() {
        checkAccessibility()
        checkNotifications()
        checkScreenCapture()
        checkMicrophone()
    }
    
    public func checkAccessibility() {
        let trusted = AXIsProcessTrusted()
        if self.isAccessibilityGranted != trusted {
            DispatchQueue.main.async {
                self.isAccessibilityGranted = trusted
            }
        }
    }
    
    public func checkNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let granted = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            DispatchQueue.main.async {
                if self?.isNotificationsGranted != granted {
                    self?.isNotificationsGranted = granted
                }
            }
        }
    }
    
    public func checkScreenCapture() {
        if #available(macOS 10.15, *) {
            let granted = CGPreflightScreenCaptureAccess()
            // Set synchronously on main: the recorder reads the flag right after this call (replay auto-start)
            if self.isScreenCaptureGranted != granted {
                if Thread.isMainThread { self.isScreenCaptureGranted = granted }
                else { DispatchQueue.main.async { self.isScreenCaptureGranted = granted } }
            }
        } else {
            self.isScreenCaptureGranted = true
        }
    }
    
    public func checkMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let granted = (status == .authorized)
        if self.isMicrophoneGranted != granted {
            DispatchQueue.main.async {
                self.isMicrophoneGranted = granted
            }
        }
    }
    
    public func requestMicrophone(completion: ((Bool) -> Void)? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            DispatchQueue.main.async {
                self.isMicrophoneGranted = true
                completion?(true)
            }
            return
        }
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isMicrophoneGranted = granted
                    completion?(granted)
                }
            }
        } else {
            openMicrophoneSettings()
            completion?(false)
        }
    }
    
    public func openMicrophoneSettings() {
        openSettingsPane(
            modernUrl: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
            legacyUrl: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            anchorName: "Privacy_Microphone"
        )
    }
    
    // MARK: - Permission Requests & System Settings Deep-links
    
    public func requestAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        
        // 1. Call AXIsProcessTrustedWithOptions with prompt option.
        // If prompt was never shown, macOS shows its native dialog.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted {
            DispatchQueue.main.async {
                self.isAccessibilityGranted = true
            }
            return
        }
        
        // 2. Open System Settings directly to Privacy & Security -> Accessibility
        openAccessibilitySettings()
    }
    
    public func openAccessibilitySettings() {
        openSettingsPane(
            modernUrl: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            legacyUrl: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            anchorName: "Privacy_Accessibility"
        )
    }
    
    public func requestNotifications() {
        NSApp.activate(ignoringOtherApps: true)
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationService.shared
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.isNotificationsGranted = granted
                if granted {
                    // Send confirmation notification
                    NotificationService.shared.sendRecordingNotification(
                        title: "Notchy",
                        body: tr("Уведомления успешно подключены!", "Notifications enabled successfully!")
                    )
                } else {
                    self?.openNotificationSettings()
                }
            }
        }
    }
    
    public func openNotificationSettings() {
        openSettingsPane(
            modernUrl: "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            legacyUrl: "x-apple.systempreferences:com.apple.preference.notifications",
            anchorName: nil
        )
    }
    
    public func requestScreenCapture() {
        NSApp.activate(ignoringOtherApps: true)
        
        // 1. Trigger system prompt if available
        if #available(macOS 10.15, *) {
            _ = CGRequestScreenCaptureAccess()
        }
        
        // 2. Open System Settings directly to Privacy & Security -> Screen & System Audio Recording
        openScreenCaptureSettings()
    }
    
    public func openScreenCaptureSettings() {
        openSettingsPane(
            modernUrl: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            legacyUrl: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            anchorName: "Privacy_ScreenCapture"
        )
    }
    
    // MARK: - Direct Navigation Helper
    
    private func openSettingsPane(modernUrl: String, legacyUrl: String, anchorName: String?) {
        // First try modern macOS 13+ URL
        if let modern = URL(string: modernUrl), NSWorkspace.shared.open(modern) {
            return
        }
        
        // Try legacy URL
        if let legacy = URL(string: legacyUrl), NSWorkspace.shared.open(legacy) {
            return
        }
        
        // Fallback: AppleScript reveal anchor in System Settings
        if let anchor = anchorName {
            let script = """
            tell application "System Settings"
                activate
                delay 0.2
                reveal anchor "\(anchor)" of pane id "com.apple.settings.PrivacySecurity.extension"
            end tell
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
        }
    }
    
    // MARK: - Relaunch App
    
    public func restartApplication() {
        let bundleURL = Bundle.main.bundleURL
        let conf = NSWorkspace.OpenConfiguration()
        conf.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: conf) { _, error in
            DispatchQueue.main.async {
                if error == nil {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

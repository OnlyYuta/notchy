import Foundation
import UserNotifications
import AppKit

public final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService()
    
    private var hasRequestedPermission = false
    private var isAuthorized = false
    
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        checkAuthorizationStatus()
    }
    
    public func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
                self?.hasRequestedPermission = true
                completion?(granted)
            }
        }
    }
    
    public func checkAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.isAuthorized = (settings.authorizationStatus == .authorized)
            }
        }
    }
    
    public func sendAgentNotification(title: String, subtitle: String? = nil, body: String) {
        guard SettingsService.shared.agentNotificationsEnabled else { return }
        
        deliverNotification(
            identifier: "notch-agent-\(UUID().uuidString)",
            title: title,
            subtitle: subtitle ?? "Notchy",
            body: body
        )
    }
    
    public func sendMusicNotification(title: String, artist: String, album: String? = nil) {
        guard SettingsService.shared.musicNotificationsEnabled else { return }
        
        deliverNotification(
            identifier: "notch-music-track",
            title: title,
            subtitle: artist,
            body: album ?? ""
        )
    }
    
    public func sendRecordingNotification(title: String, body: String) {
        deliverNotification(
            identifier: "notch-recording-\(UUID().uuidString)",
            title: title,
            subtitle: "Notchy",
            body: body
        )
    }
    
    private func deliverNotification(identifier: String, title: String, subtitle: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Deliver immediately
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }
    
    // Show banner even when app is active
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

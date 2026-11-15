import Foundation
import SwiftUI
import Combine
import IOKit.pwr_mgt
import AppKit

/// How long "Keep awake" stays on after it is switched on.
public enum KeepAwakeDuration: Int, CaseIterable, Identifiable {
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200
    case fiveHours = 18000
    case forever = 0
    
    public var id: Int { rawValue }
    
    public var title: String {
        switch self {
        case .thirtyMinutes: return tr("30 мин", "30 min")
        case .oneHour: return tr("1 час", "1 hour")
        case .twoHours: return tr("2 часа", "2 hours")
        case .fiveHours: return tr("5 часов", "5 hours")
        case .forever: return tr("Бессрочно", "Forever")
        }
    }
}

public final class SettingsService: ObservableObject {
    public static let shared = SettingsService()
    
    private let visibleTabsKey = "notch_visible_tabs"
    private let tabOrderKey = "notch_tab_order"
    private let agentNotifKey = "notch_agent_notifications"
    private let musicNotifKey = "notch_music_notifications"
    private let disableExternalKey = "notch_disable_on_external_displays"
    private let revealOnHoverExternalKey = "notch_reveal_on_hover_external"
    private let preventSleepKey = "notch_prevent_sleep"
    
    @Published public var preventSleepEnabled: Bool {
        didSet {
            UserDefaults.standard.set(preventSleepEnabled, forKey: preventSleepKey)
            SleepPreventionService.shared.setSleepPrevention(enabled: preventSleepEnabled)
            // Switching on starts the countdown from now; switching off cancels it
            if preventSleepEnabled { restartKeepAwakeTimer() } else { clearKeepAwakeTimer() }
            syncClosedLid()
        }
    }
    
    // MARK: Closed lid
    
    private let closedLidKey = "notch_keepawake_closed_lid"
    private let closedLidAppliedKey = "notch_closedlid_applied"
    
    /// Also stay awake when the lid is closed. Closing the lid is a forced sleep that idle-sleep assertions don't stop, so this
    /// sets the system flag `pmset disablesleep` (asks for the administrator password) for as long as keep-awake is on.
    @Published public var keepAwakeClosedLid: Bool {
        didSet {
            UserDefaults.standard.set(keepAwakeClosedLid, forKey: closedLidKey)
            syncClosedLid()
        }
    }
    /// Whether `disablesleep` is currently set by us (remembered across launches so it can always be undone)
    @Published public private(set) var closedLidActive: Bool
    
    private func syncClosedLid() {
        let want = preventSleepEnabled && keepAwakeClosedLid
        guard want != closedLidActive else { return }
        Self.setSleepDisabled(want) { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.closedLidActive = want
                UserDefaults.standard.set(want, forKey: self.closedLidAppliedKey)
            } else if want {
                // Password refused or cancelled: don't pretend the lid is covered
                self.keepAwakeClosedLid = false
            }
        }
    }
    
    /// `pmset disablesleep` needs root; AppleScript shows the standard administrator password dialog.
    private static func setSleepDisabled(_ on: Bool, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = runSleepDisabled(on)
            DispatchQueue.main.async { completion(ok) }
        }
    }
    
    @discardableResult
    fileprivate static func runSleepDisabled(_ on: Bool) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "do shell script \"/usr/bin/pmset -a disablesleep \(on ? 1 : 0)\" with administrator privileges"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
    
    private let keepAwakeDurationKey = "notch_keepawake_duration"
    private let keepAwakeEndKey = "notch_keepawake_ends_at"
    private var keepAwakeWork: DispatchWorkItem?
    
    /// Chosen length of the keep-awake session; changing it while active restarts the countdown from now.
    @Published public var keepAwakeDuration: KeepAwakeDuration {
        didSet {
            UserDefaults.standard.set(keepAwakeDuration.rawValue, forKey: keepAwakeDurationKey)
            if preventSleepEnabled { restartKeepAwakeTimer() }
        }
    }
    /// When the current session ends (nil = no limit or not active)
    @Published public private(set) var keepAwakeEndsAt: Date?
    
    private func restartKeepAwakeTimer() {
        keepAwakeWork?.cancel()
        guard keepAwakeDuration != .forever else {
            keepAwakeEndsAt = nil
            UserDefaults.standard.removeObject(forKey: keepAwakeEndKey)
            return
        }
        scheduleKeepAwakeEnd(at: Date().addingTimeInterval(TimeInterval(keepAwakeDuration.rawValue)))
    }
    
    private func scheduleKeepAwakeEnd(at end: Date) {
        keepAwakeWork?.cancel()
        keepAwakeEndsAt = end
        UserDefaults.standard.set(end.timeIntervalSince1970, forKey: keepAwakeEndKey)
        let work = DispatchWorkItem { [weak self] in self?.expireKeepAwakeIfDue() }
        keepAwakeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(end.timeIntervalSinceNow, 0), execute: work)
    }
    
    private func clearKeepAwakeTimer() {
        keepAwakeWork?.cancel()
        keepAwakeWork = nil
        keepAwakeEndsAt = nil
        UserDefaults.standard.removeObject(forKey: keepAwakeEndKey)
    }
    
    /// Switches keep-awake off once the time is up (also checked after the Mac wakes, as timers pause during sleep).
    public func expireKeepAwakeIfDue() {
        guard preventSleepEnabled, let end = keepAwakeEndsAt, end <= Date() else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { preventSleepEnabled = false }
    }
    
    /// Порядок вкладок в челке; вкладку «Настройки» всегда оставляем последней.
    @Published public var tabOrder: [ExpandedTab] = {
        let saved = (UserDefaults.standard.stringArray(forKey: "notch_tab_order") ?? []).compactMap(ExpandedTab.init(rawValue:))
        let rest = [ExpandedTab.agents, .music, .record, .clipboard].filter { !saved.contains($0) }
        return (saved + rest).filter { $0 != .settings }
    }() {
        didSet { UserDefaults.standard.set(tabOrder.map(\.rawValue), forKey: tabOrderKey) }
    }

    @Published public var visibleTabs: Set<ExpandedTab> {
        didSet {
            saveVisibleTabs()
        }
    }
    
    @Published public var agentNotificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(agentNotificationsEnabled, forKey: agentNotifKey)
            if agentNotificationsEnabled {
                NotificationService.shared.requestAuthorization()
            }
        }
    }
    
    @Published public var agentDoneSoundEnabled: Bool {
        didSet { UserDefaults.standard.set(agentDoneSoundEnabled, forKey: "agent_done_sound") }
    }
    
    @Published public var mouseSideButtonsTabs: Bool {
        didSet { UserDefaults.standard.set(mouseSideButtonsTabs, forKey: "mouse_side_buttons_tabs") }
    }
    
    @Published public var musicNotificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(musicNotificationsEnabled, forKey: musicNotifKey)
            if musicNotificationsEnabled {
                NotificationService.shared.requestAuthorization()
            }
        }
    }
    
    /// "auto" (built-in display) or a CGDirectDisplayID: the one monitor the notch lives on
    @Published public var notchDisplayID: String = UserDefaults.standard.string(forKey: "notch_display_id") ?? "auto" {
        didSet { UserDefaults.standard.set(notchDisplayID, forKey: "notch_display_id") }
    }
    
    @Published public var disableOnExternalDisplays: Bool {
        didSet {
            UserDefaults.standard.set(disableOnExternalDisplays, forKey: disableExternalKey)
        }
    }
    
    @Published public var revealOnHoverOnExternalDisplays: Bool {
        didSet {
            UserDefaults.standard.set(revealOnHoverOnExternalDisplays, forKey: revealOnHoverExternalKey)
        }
    }
    
    // Connection tracking
    @Published public private(set) var isAgentConnected: Bool = false
    @Published public private(set) var activeSessionCount: Int = 0
    @Published public private(set) var lastSyncTime: Date? = nil
    @Published public private(set) var isConnecting: Bool = false
    
    private var connectionTimer: Timer?
    
    private init() {
        // Load visible tabs
        // Decoded name by name: a tab that no longer exists (the old Icons tab) is skipped instead of failing the set
        let savedTabs = (UserDefaults.standard.data(forKey: visibleTabsKey)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []).compactMap(ExpandedTab.init(rawValue:))
        self.visibleTabs = savedTabs.isEmpty ? [.agents, .music, .record, .clipboard] : Set(savedTabs)
        
        // Load notifications settings (default agent: true, music: false)
        if UserDefaults.standard.object(forKey: agentNotifKey) != nil {
            self.agentNotificationsEnabled = UserDefaults.standard.bool(forKey: agentNotifKey)
        } else {
            self.agentNotificationsEnabled = true
        }
        
        self.agentDoneSoundEnabled = UserDefaults.standard.object(forKey: "agent_done_sound") as? Bool ?? true
        self.mouseSideButtonsTabs = UserDefaults.standard.object(forKey: "mouse_side_buttons_tabs") as? Bool ?? true
        self.musicNotificationsEnabled = UserDefaults.standard.bool(forKey: musicNotifKey)
        
        // Load external displays settings (default disable: false, reveal on hover: true)
        self.disableOnExternalDisplays = UserDefaults.standard.bool(forKey: disableExternalKey)
        // The toggle was removed from settings: always on, so a stored "off" can't leave the notch unreachable
        self.revealOnHoverOnExternalDisplays = true
        
        // Load keep awake / prevent sleep setting (default: false)
        let sleepPref = UserDefaults.standard.bool(forKey: preventSleepKey)
        self.keepAwakeDuration = KeepAwakeDuration(rawValue: UserDefaults.standard.integer(forKey: keepAwakeDurationKey)) ?? .forever
        self.keepAwakeClosedLid = UserDefaults.standard.bool(forKey: closedLidKey)
        self.closedLidActive = UserDefaults.standard.bool(forKey: closedLidAppliedKey)
        self.preventSleepEnabled = sleepPref
        SleepPreventionService.shared.setSleepPrevention(enabled: sleepPref)
        // A timed session survives a relaunch: resume the countdown, or end it if its time already ran out
        if sleepPref, UserDefaults.standard.object(forKey: keepAwakeEndKey) != nil {
            let end = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: keepAwakeEndKey))
            if end > Date() { scheduleKeepAwakeEnd(at: end) } else { DispatchQueue.main.async { [weak self] in self?.preventSleepEnabled = false } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.expireKeepAwakeIfDue()
        }
        // Never leave the Mac unable to sleep behind: undo the lid override when the app quits, and on the next launch if it was missed
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.closedLidActive else { return }
            if Self.runSleepDisabled(false) { UserDefaults.standard.set(false, forKey: self.closedLidAppliedKey) }
        }
        DispatchQueue.main.async { [weak self] in self?.syncClosedLid() }
        
        checkConnection()
        startConnectionMonitor()
    }
    
    private func saveVisibleTabs() {
        if let data = try? JSONEncoder().encode(visibleTabs) {
            UserDefaults.standard.set(data, forKey: visibleTabsKey)
        }
    }
    
    public func isTabVisible(_ tab: ExpandedTab) -> Bool {
        visibleTabs.contains(tab)
    }
    
    public func toggleTabVisibility(_ tab: ExpandedTab) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            if visibleTabs.contains(tab) {
                // Keep at least one tab visible
                if visibleTabs.count > 1 {
                    visibleTabs.remove(tab)
                }
            } else {
                visibleTabs.insert(tab)
            }
        }
    }
    
    public func checkConnection() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let brainDir = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/antigravity/brain")
            guard FileManager.default.fileExists(atPath: brainDir),
                  let sessions = try? FileManager.default.contentsOfDirectory(atPath: brainDir) else {
                DispatchQueue.main.async {
                    self.isAgentConnected = false
                    self.activeSessionCount = 0
                }
                return
            }
            
            let now = Date()
            var count = 0
            for item in sessions {
                let logPath = "\(brainDir)/\(item)/.system_generated/logs/transcript.jsonl"
                if FileManager.default.fileExists(atPath: logPath),
                   let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
                   let modDate = attrs[.modificationDate] as? Date,
                   now.timeIntervalSince(modDate) < 14400 { // active in last 4 hours
                    count += 1
                }
            }
            
            DispatchQueue.main.async {
                self.isAgentConnected = count > 0 || !sessions.isEmpty
                self.activeSessionCount = count
                self.lastSyncTime = Date()
            }
        }
    }
    
    public func connectAgents() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            self.isConnecting = true
        }
        
        TranscriptWatcher.shared.start()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            usleep(300000) // 300ms simulated connection refresh
            self?.checkConnection()
            
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    self?.isConnecting = false
                }
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }
        }
    }
    
    private func startConnectionMonitor() {
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.checkConnection()
        }
    }
}

// MARK: - Sleep Prevention Service (IOKit Power Management)

public final class SleepPreventionService: ObservableObject {
    public static let shared = SleepPreventionService()
    
    @Published public private(set) var isSleepPrevented: Bool = false
    
    private var systemSleepAssertionID: IOPMAssertionID = 0
    private var displaySleepAssertionID: IOPMAssertionID = 0
    
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }
    
    deinit {
        releaseAssertions()
    }
    
    @objc private func applicationWillTerminate() {
        releaseAssertions()
    }
    
    public func setSleepPrevention(enabled: Bool) {
        if enabled {
            enableSleepPrevention()
        } else {
            disableSleepPrevention()
        }
    }
    
    private func enableSleepPrevention() {
        guard !isSleepPrevented else { return }
        
        let reason = ("Notchy: Prevent Sleep While Agents Working" as CFString)
        
        // 1. Prevent idle system sleep (CPU, networking, processes stay 100% active)
        let sysResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &systemSleepAssertionID
        )
        
        // 2. Prevent idle display sleep (keeps screen and system awake)
        let dispResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displaySleepAssertionID
        )
        
        if sysResult == kIOReturnSuccess || dispResult == kIOReturnSuccess {
            DispatchQueue.main.async {
                self.isSleepPrevented = true
            }
        }
    }
    
    private func disableSleepPrevention() {
        releaseAssertions()
        DispatchQueue.main.async {
            self.isSleepPrevented = false
        }
    }
    
    private func releaseAssertions() {
        if systemSleepAssertionID != 0 {
            IOPMAssertionRelease(systemSleepAssertionID)
            systemSleepAssertionID = 0
        }
        if displaySleepAssertionID != 0 {
            IOPMAssertionRelease(displaySleepAssertionID)
            displaySleepAssertionID = 0
        }
    }
}

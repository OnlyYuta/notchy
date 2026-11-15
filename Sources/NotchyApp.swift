import SwiftUI
import AppKit
import Combine

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var tabsSubscription: AnyCancellable?
    private var runningTabs: Set<ExpandedTab>?
    
    /// Starts the services of tabs switched on and stops those of tabs switched off; only changes are acted on.
    private func applyTabServices(_ tabs: Set<ExpandedTab>) {
        let changed = { (tab: ExpandedTab) -> Bool? in
            let on = tabs.contains(tab)
            return self.runningTabs?.contains(tab) == on ? nil : on
        }
        if let on = changed(.music) { on ? NowPlayingService.shared.start() : NowPlayingService.shared.stop() }
        if let on = changed(.agents) {
            if on {
                AgentEventsWatcher.shared.start()
                TranscriptWatcher.shared.start()
            } else {
                AgentEventsWatcher.shared.stop()
                TranscriptWatcher.shared.stop()
            }
            AgentStatusService.shared.setEnabled(on)
        }
        if let on = changed(.record) {
            on ? GlobalHotkeyManager.shared.startMonitoring() : GlobalHotkeyManager.shared.stopMonitoring()
            // At launch the recorder sets itself up from the same setting
            if runningTabs != nil { ScreenRecorderService.shared.setEnabled(on) }
        }
        if let on = changed(.clipboard), runningTabs != nil || !on { ClipboardService.shared.setEnabled(on) }
        if runningTabs == nil {
            // Created here so its own init applies the setting (clipboard history)
            _ = ClipboardService.shared
        }
        runningTabs = tabs
    }
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as accessory/agent (no Dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Present Notchy overlay
        DispatchQueue.main.async {
            NotchWindowController.shared.show()
            NotchWindowController.startExtraDisplays()
            // Deploy and register universal hooks for Antigravity, Claude Code, Cursor
            AgentHookManager.shared.installHooks()
            // Each tab's services run only while the tab is switched on in settings (now and on every change)
            self.tabsSubscription = SettingsService.shared.$visibleTabs
                .receive(on: RunLoop.main)
                .sink { [weak self] tabs in self?.applyTabServices(tabs) }
            
            // Show Onboarding if first launch; the notch waits out of sight until the welcome window is done
            if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
                NotchWindowController.shared.holdForIntro()
                OnboardingWindowController.shared.show()
            }
        }
    }
}

@main
public struct NotchyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // @AppStorage, not SettingsService: MenuBarExtra writes this binding on every update, and an @Published
    // re-announces even an unchanged value, which turned every menu refresh into the next one (a full-speed loop).
    // Off: settings stay reachable from the Settings tab of the notch.
    @AppStorage("show_menu_bar_icon") private var showMenuBarIcon = true
    
    public init() {}
    
    public var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarContentView()
        } label: {
            Image(nsImage: MenuBarGlyph.image)
        }
    }
}

/// Menu bar icon: the app icon's silhouette (rounded screen with the notch cut out of its top). A template image,
/// so macOS tints it for light, dark and highlighted menu bars.
enum MenuBarGlyph {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1.5), xRadius: 4.5, yRadius: 4.5).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(roundedRect: NSRect(x: 4.5, y: 10.1, width: 9, height: 4.6), xRadius: 2.3, yRadius: 2.3).fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

struct MenuBarContentView: View {
    @ObservedObject private var notchManager = NotchManager.shared
    @ObservedObject private var l10n = LocalizationService.shared
    @ObservedObject private var agentService = AgentStatusService.shared
    @ObservedObject private var nowPlayingService = NowPlayingService.shared
    @ObservedObject private var recorder = ScreenRecorderService.shared
    @ObservedObject private var settings = SettingsService.shared
    
    private func stateText(_ state: WorkState) -> String {
        switch state {
        case .needsConfirmation: return tr("Нужно ваше подтверждение", "Needs your confirmation")
        case .done: return tr("Задача завершена", "Task finished")
        default: return tr("Выполняет задачу", "Working on a task")
        }
    }
    
    private func short(_ text: String, _ limit: Int = 38) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
    
    var body: some View {
        // What is happening now: agents that work and the track; each block only when there is something to show
        let busy = agentService.instances.filter { $0.workState != .idle }
        if !busy.isEmpty {
            Section(tr("Агенты", "Agents")) {
                ForEach(busy) { inst in
                    Text("\(inst.agent.displayName) · \(inst.projectName.isEmpty ? "—" : inst.projectName): \(stateText(inst.workState))")
                }
            }
        }
        
        if let track = nowPlayingService.currentTrack {
            Button(action: { nowPlayingService.togglePlayPause() }) {
                Label(short(track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"),
                      systemImage: nowPlayingService.isPlaying ? "pause.fill" : "play.fill")
            }
        }
        
        if !busy.isEmpty || nowPlayingService.currentTrack != nil { Divider() }
        
        if settings.isTabVisible(.record) {
            Button(action: { recorder.toggleManualRecording() }) {
                Label(recorder.isRecording ? l10n.t(.stopRecording) : l10n.t(.startRecording),
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
            }
            Button(action: { recorder.saveInstantReplay() }) {
                Label(l10n.t(.saveReplayButton), systemImage: "arrow.down.circle")
            }
            .disabled(!recorder.isReplayActive || recorder.isSavingReplay)
            Toggle(tr("Мгновенный повтор", "Instant Replay"),
                   isOn: Binding(get: { recorder.isReplayActive }, set: { _ in recorder.toggleReplayBuffer() }))
        }
        Toggle(tr("Не давать засыпать", "Keep awake"), isOn: $settings.preventSleepEnabled)
        
        Divider()
        
        Button(action: { AppSettingsWindowController.shared.show() }) {
            Label(tr("Настройки...", "Settings..."), systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)
        
        // Rarely needed: kept out of the main list
        Menu(tr("Дополнительно", "More")) {
            Button(tr("Приветствие и разрешения...", "Welcome and permissions...")) {
                OnboardingWindowController.shared.show()
            }
            Divider()
            Button(tr("Переустановить интеграцию с агентами", "Reinstall agent integration")) {
                AgentHookManager.shared.installHooks(force: true)
            }
            Button(tr("Удалить хуки из конфигов агентов", "Remove hooks from agent configs")) {
                AgentHookManager.shared.removeHooks()
            }
            Button(tr("Обновить положение", "Refresh position")) {
                notchManager.refresh()
                NotchWindowController.shared.updateFrame()
            }
        }
        
        Divider()
        
        Button(tr("Завершить", "Quit")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

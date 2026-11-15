import SwiftUI
import AppKit
import Combine

public enum ExpandedTab: String, CaseIterable, Identifiable, Codable {
    case agents = "agents"
    case music = "music"
    case record = "record"
    case clipboard = "clipboard"
    case settings = "settings"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .agents: return LocalizationService.shared.t(.tabAgents)
        case .music: return LocalizationService.shared.t(.tabMusic)
        case .record: return LocalizationService.shared.t(.tabRecord)
        case .clipboard: return LocalizationService.shared.t(.tabClipboard)
        case .settings: return LocalizationService.shared.t(.tabSettings)
        }
    }
    
    public var icon: String {
        switch self {
        case .agents: return "sparkles"
        case .music: return "music.note"
        case .record: return "record.circle"
        case .clipboard: return "doc.on.clipboard"
        case .settings: return "gearshape.fill"
        }
    }
}

public final class NotchViewModel: ObservableObject {
    @Published public var isHovered: Bool = false {
        didSet {
            guard oldValue != isHovered else { return }
            if isHovered {
                wingCollapseTimer?.cancel()
                wingCollapseTimer = nil
                isTemporaryWingExpanded = false
                temporaryMode = nil
                // Recording: open on its tab every time, so stopping is one click away.
                // Opening the notch with a finished agent waiting: show it, otherwise the 6 s dismissal never starts
                // (it only runs while the Agents tab is on screen) and the check would stay forever.
                if isRecordingScreen, visibleTabs.contains(.record) {
                    selectedTab = .record
                } else if selectedTab != .agents, !isRecordingScreen, visibleTabs.contains(.agents), NSEvent.pressedMouseButtons == 0,
                   AgentStatusService.shared.instances.contains(where: { $0.workState == .done }) {
                    selectedTab = .agents
                }
            }
            updateAgentsTabViewingState()
        }
    }
    @Published public var selectedTab: ExpandedTab = .agents {
        didSet {
            guard oldValue != selectedTab else { return }
            updateAgentsTabViewingState()
        }
    }
    @Published public private(set) var notchInfo: NotchInfo
    @Published public private(set) var activeAgentCount: Int = 0
    @Published public private(set) var activeAgents: [AgentType] = [.antigravity]
    @Published public private(set) var currentAgent: AgentType = .antigravity
    @Published public private(set) var workingAgents: [AgentType] = [.antigravity]
    @Published public private(set) var workingInstances: [AgentInstance] = []
    @Published public private(set) var workState: WorkState = .idle
    @Published public private(set) var isMusicPlaying: Bool = false
    @Published public private(set) var currentTrack: TrackInfo? = nil
    @Published public private(set) var isRecordingScreen: Bool = false
    /// First launch: the notch stays hidden while the welcome window is open, then drops in (see NotchWindowController.playIntro).
    @Published public var isIntroHidden: Bool = false
    /// Drives the colour sweep around the notch right after it appears.
    @Published public var introGlow: Bool = false
    /// Files being dragged toward the notch (read from the drag pasteboard); drives the format blocks.
    @Published public var draggedFiles: [URL] = [] {
        didSet { conversionTargets = draggedFiles.isEmpty ? [] : FileConverter.targets(for: draggedFiles) }
    }
    /// Format blocks for the drag in progress, computed once per drag (not on every redraw).
    @Published public private(set) var conversionTargets: [ConversionTarget] = []
    
    // 2-second temporary wing expansion for track start & agent launch
    @Published public private(set) var isTemporaryWingExpanded: Bool = false
    @Published public private(set) var isWaitingConfirmation: Bool = false
    @Published public private(set) var temporaryMode: NotchMode? = nil
    private var wingCollapseTimer: DispatchWorkItem?
    
    public enum NotchMode {
        case agent
        case music
        case replaySaved
        case idle
    }
    
    /// Motion, Dynamic Island style: opening grows with a slight overshoot, closing settles back without bouncing,
    /// small controls answer fast.
    public static let springAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.78)
    public static let closeAnimation: Animation = .spring(response: 0.34, dampingFraction: 0.94)
    public static let snappyAnimation: Animation = .spring(response: 0.26, dampingFraction: 0.86)
    
    /// Width of the open card
    public static let openWidth: CGFloat = 600
    /// Height of a tab button, and of the second tab row with its spacing
    public static let tabHeight: CGFloat = 24
    public static let tabRowStep: CGFloat = 30
    /// The camera housing is kept clear of tabs by this much on each side
    public static let cutoutMargin: CGFloat = 10
    
    // Window bounding box (must comfortably contain expanded states with multiple rows, clipboard and menu bar)
    public let windowWidth: CGFloat = 780.0
    public let windowHeight: CGFloat = 330.0
    
    private var cancellables = Set<AnyCancellable>()
    
    /// `screen`: a notch pinned to that monitor ("all displays" mode); nil follows the monitor chosen in settings
    public init(screen: NSScreen? = nil, manager: NotchManager = .shared, agentService: AgentStatusService = .shared, nowPlayingService: NowPlayingService = .shared) {
        self.notchInfo = screen.map(NotchManager.notchInfo(for:)) ?? manager.currentNotch
        self.activeAgentCount = agentService.activeAgents.count
        self.activeAgents = agentService.activeAgents
        self.currentAgent = agentService.currentAgent
        self.workingAgents = agentService.workingAgents
        self.workingInstances = agentService.workingInstances
        self.workState = agentService.workState
        self.isMusicPlaying = nowPlayingService.isPlaying
        self.currentTrack = nowPlayingService.currentTrack
        let initialShowAgents = SettingsService.shared.isTabVisible(.agents) && agentService.isAnyAgentAppRunning
        if !initialShowAgents {
            self.selectedTab = .music
        }
        
        if screen == nil {
            manager.$currentNotch
                .receive(on: RunLoop.main)
                .sink { [weak self] newNotch in
                    self?.notchInfo = newNotch
                }
                .store(in: &cancellables)
        }
            
        agentService.$activeAgents
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                guard let self = self, self.activeAgents != list else { return }
                withAnimation(Self.springAnimation) {
                    self.activeAgents = list
                    self.activeAgentCount = list.count
                }
            }
            .store(in: &cancellables)
            
        agentService.$currentAgent
            .receive(on: RunLoop.main)
            .sink { [weak self] agent in
                guard let self = self, self.currentAgent != agent else { return }
                withAnimation(Self.springAnimation) {
                    self.currentAgent = agent
                }
            }
            .store(in: &cancellables)
            
        agentService.$workingAgents
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                guard let self = self, self.workingAgents != list else { return }
                withAnimation(Self.springAnimation) {
                    self.workingAgents = list
                }
            }
            .store(in: &cancellables)
            
        agentService.$instances
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let newInstances = agentService.workingInstances
                if self.workingInstances != newInstances {
                    withAnimation(Self.springAnimation) {
                        self.workingInstances = newInstances
                    }
                }
            }
            .store(in: &cancellables)
            
        agentService.$requestedTab
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] tab in
                guard let self = self else { return }
                withAnimation(Self.springAnimation) {
                    if tab == "music" {
                        self.selectedTab = .music
                    } else if tab == "agents" || tab == "agent" {
                        self.selectedTab = .agents
                    } else if tab == "clipboard" || tab == "buffer" || tab == "буфер" {
                        self.selectedTab = .clipboard
                    }
                }
                AgentStatusService.shared.requestedTab = nil
            }
            .store(in: &cancellables)
            
        agentService.$workState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                let changed = self.workState != state
                self.workState = state
                self.workingInstances = agentService.workingInstances
                self.updateAgentsTabViewingState()
                if changed {
                    if state == .needsConfirmation {
                        self.wingCollapseTimer?.cancel()
                        self.wingCollapseTimer = nil
                        withAnimation(Self.springAnimation) {
                            self.isWaitingConfirmation = true
                            self.temporaryMode = .agent
                            if !self.isHovered && !self.isRecordingScreen {
                                self.selectedTab = .agents
                            }
                        }
                    } else {
                        if self.isWaitingConfirmation {
                            withAnimation(Self.springAnimation) {
                                self.isWaitingConfirmation = false
                            }
                        }
                        if state == .working || state == .promptReceived {
                            if SettingsService.shared.agentNotificationsEnabled {
                                if !self.isHovered && !self.isRecordingScreen {
                                    self.selectedTab = .agents
                                }
                                self.triggerTemporaryWingExpansion(duration: 2.0, mode: .agent)
                            }
                        } else if state == .done {
                            if SettingsService.shared.agentDoneSoundEnabled { NSSound(named: "Glass")?.play() }
                            if SettingsService.shared.agentNotificationsEnabled {
                                if !self.isHovered && !self.isRecordingScreen {
                                    self.selectedTab = .agents
                                }
                                self.triggerTemporaryWingExpansion(duration: 6.0, mode: .agent)
                            }
                        } else if state == .idle {
                            self.wingCollapseTimer?.cancel()
                            self.wingCollapseTimer = nil
                            withAnimation(Self.springAnimation) {
                                self.isTemporaryWingExpanded = false
                                self.temporaryMode = nil
                                self.isWaitingConfirmation = false
                                if self.selectedTab == .agents && !self.visibleTabs.contains(.agents) {
                                    self.selectedTab = self.visibleTabs.first(where: { $0 != .agents }) ?? .music
                                }
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)
            
        agentService.$cliSessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
            
        agentService.$runningAgents
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
            
        Publishers.CombineLatest3(agentService.$isAnyAgentAppRunning, agentService.$instances, agentService.$workState)
            .receive(on: RunLoop.main)
            .sink { [weak self] isRunning, instances, state in
                guard let self = self else { return }
                self.objectWillChange.send()
                self.workingInstances = agentService.workingInstances
                let shouldShowAgents = SettingsService.shared.isTabVisible(.agents) && isRunning
                
                if !shouldShowAgents && self.selectedTab == .agents {
                    withAnimation(Self.springAnimation) {
                        self.selectedTab = self.visibleTabs.first(where: { $0 != .agents }) ?? .music
                    }
                }
            }
            .store(in: &cancellables)
            
        nowPlayingService.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                guard let self = self else { return }
                let changed = self.isMusicPlaying != playing
                self.isMusicPlaying = playing
                if changed && playing {
                    if SettingsService.shared.musicNotificationsEnabled {
                        if !self.isHovered {
                            self.selectedTab = .music
                        }
                        self.triggerTemporaryWingExpansion(duration: 2.0, mode: .music)
                    }
                }
            }
            .store(in: &cancellables)
            
        nowPlayingService.$currentTrack
            .receive(on: RunLoop.main)
            .sink { [weak self] track in
                guard let self = self else { return }
                let titleChanged = self.currentTrack?.title != track?.title
                self.currentTrack = track
                if titleChanged && track != nil && self.isMusicPlaying {
                    if SettingsService.shared.musicNotificationsEnabled {
                        if !self.isHovered {
                            self.selectedTab = .music
                        }
                        self.triggerTemporaryWingExpansion(duration: 2.0, mode: .music)
                    }
                }
            }
            .store(in: &cancellables)
            
        SettingsService.shared.$musicNotificationsEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self = self else { return }
                if !enabled && self.isTemporaryWingExpanded && self.temporaryMode == .music {
                    self.wingCollapseTimer?.cancel()
                    self.wingCollapseTimer = nil
                    withAnimation(Self.springAnimation) {
                        self.isTemporaryWingExpanded = false
                        self.temporaryMode = nil
                    }
                }
            }
            .store(in: &cancellables)
            
        SettingsService.shared.$agentNotificationsEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self = self else { return }
                if !enabled && self.isTemporaryWingExpanded && self.temporaryMode == .agent {
                    self.wingCollapseTimer?.cancel()
                    self.wingCollapseTimer = nil
                    withAnimation(Self.springAnimation) {
                        self.isTemporaryWingExpanded = false
                        self.temporaryMode = nil
                    }
                }
            }
            .store(in: &cancellables)
            
        SettingsService.shared.$tabOrder
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
            
        SettingsService.shared.$visibleTabs
            .receive(on: RunLoop.main)
            .sink { [weak self] tabs in
                guard let self = self else { return }
                self.objectWillChange.send()
                if self.selectedTab != .settings && !tabs.contains(self.selectedTab) {
                    if let first = self.visibleTabs.first {
                        withAnimation(Self.springAnimation) {
                            self.selectedTab = first
                        }
                    }
                }
            }
            .store(in: &cancellables)
            
        LocalizationService.shared.$currentLanguage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
            
        SettingsService.shared.$disableOnExternalDisplays
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
            
        SettingsService.shared.$revealOnHoverOnExternalDisplays
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
            
        ScreenRecorderService.shared.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] rec in
                guard let self = self else { return }
                withAnimation(Self.springAnimation) {
                    self.isRecordingScreen = rec
                    if rec { self.selectedTab = .record }
                }
            }
            .store(in: &cancellables)
            
        ScreenRecorderService.shared.replaySavedSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.triggerTemporaryWingExpansion(duration: 2.5, mode: .replaySaved)
            }
            .store(in: &cancellables)
            
        // Start monitoring user hotkeys
        _ = GlobalHotkeyManager.shared
    }
    
    public var visibleTabs: [ExpandedTab] {
        // The agents tab stays while an agent app is open, even if it is idle
        var list = SettingsService.shared.tabOrder.filter { tab in
            SettingsService.shared.isTabVisible(tab) &&
                (tab != .agents || AgentStatusService.shared.isAnyAgentAppRunning)
        }
        list.append(.settings)
        return list
    }
    
    /// Rows of the Agents tab: working sessions first, then open-but-idle agent apps.
    public var agentRows: [AgentInstance] {
        let working = workingInstances
        let service = AgentStatusService.shared
        // Terminal sessions are listed per project; an agent without any (an app, or a session whose folder is unknown) gets one row
        let sessions = service.cliSessions.filter { s in !working.contains { $0.agent == s.agent && $0.projectName == s.projectName } }
        let idle = sessions + service.runningAgents
            .filter { agent in !working.contains { $0.agent == agent } && !service.cliSessions.contains { $0.agent == agent } }
            .map { AgentInstance(id: "idle-\($0.rawValue)", agent: $0, projectName: "", workState: .idle) }
        return working + idle
    }
    
    private func updateAgentsTabViewingState() {
        if isHovered && selectedTab == .agents {
            AgentStatusService.shared.startViewingAgentsTab()
        } else {
            AgentStatusService.shared.cancelViewingAgentsTab()
        }
    }
    
    // MARK: - Temporary 2-Second Wing Expansion
    
    /// duration nil = stay expanded until the notch is hovered.
    public func triggerTemporaryWingExpansion(duration: Double? = 2.0, mode: NotchMode) {
        guard !isHovered else { return }
        if mode == .music && !SettingsService.shared.musicNotificationsEnabled {
            return
        }
        if mode == .agent && !SettingsService.shared.agentNotificationsEnabled {
            return
        }
        
        wingCollapseTimer?.cancel()
        wingCollapseTimer = nil
        
        withAnimation(Self.springAnimation) {
            self.temporaryMode = mode
            self.isTemporaryWingExpanded = true
        }
        
        guard let duration = duration else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isHovered else { return }
            withAnimation(Self.springAnimation) {
                self.isTemporaryWingExpanded = false
                self.temporaryMode = nil
            }
        }
        self.wingCollapseTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
    
    // Idle dimensions (matches the physical notch)
    public var idleWidth: CGFloat {
        notchInfo.notchSize.width
    }
    
    public var idleHeight: CGFloat {
        notchInfo.notchSize.height
    }
    
    /// The band the tabs sit in: the notch's height, but never too short for a tab (some displays report a low notch)
    public var tabBandHeight: CGFloat {
        max(idleHeight, Self.tabHeight + 8)
    }
    
    // Base expanded dimensions
    public var baseExpandedWidth: CGFloat {
        notchInfo.notchSize.width + 65.0
    }
    
    public var activeMode: NotchMode {
        if isHovered {
            return selectedTab == .music ? .music : .agent
        }
        if isWaitingConfirmation {
            return .agent
        }
        if isTemporaryWingExpanded {
            return temporaryMode ?? (isMusicPlaying ? .music : .agent)
        }
        return .idle
    }
    
    // Count of distinct active working agents (e.g. Antigravity, Claude)
    public var workingAgentCount: Int {
        let uniqueAgents = Set(workingInstances.map { $0.agent })
        if !uniqueAgents.isEmpty {
            return uniqueAgents.count
        }
        if !workingAgents.isEmpty && (workState == .working || workState == .needsConfirmation) {
            return Set(workingAgents).count
        }
        if workState == .working || workState == .needsConfirmation {
            return 1
        }
        return 0
    }
    
    /// Width the notch settles at when not hovered (idle, or the event/recording wings). The wing contents fade in only as the
    /// notch actually arrives at it, so nothing slides out of the edges while the card is still collapsing.
    public var restingWidth: CGFloat { isVisuallyExpanded ? expandedWidth : idleWidth }
    
    public var expandedWidth: CGFloat {
        if isHovered {
            return Self.openWidth
        }
        
        // While recording the wings need room for the elapsed time on one line
        if isRecordingScreen && activeMode != .agent && activeMode != .music {
            return baseExpandedWidth + 34.0
        }
        
        // Unhovered temporary 2-second wing expansion:
        if activeMode == .agent {
            let count = min(4, workingAgentCount)
            let extraForMultipleAgents: CGFloat = count >= 2 ? CGFloat(count - 1) * 20.0 : 0.0
            
            let targetWidth: CGFloat
            switch workState {
            case .needsConfirmation:
                targetWidth = baseExpandedWidth + 12.0 + extraForMultipleAgents
            case .done:
                targetWidth = baseExpandedWidth + 12.0
            case .working:
                targetWidth = baseExpandedWidth + 12.0 + extraForMultipleAgents
            case .promptReceived:
                targetWidth = baseExpandedWidth + extraForMultipleAgents
            case .idle:
                targetWidth = baseExpandedWidth
            }
            return min(windowWidth - 20.0, targetWidth)
        } else if activeMode == .music {
            return baseExpandedWidth + 10.0
        } else {
            return baseExpandedWidth
        }
    }
    
    // One fixed card size for every tab: switching tabs (e.g. by swipe) must never move the card out from under the cursor
    public var expandedHeight: CGFloat {
        // The tabs live in the band beside the camera; 109 is the content area under it
        tabBandHeight + 109.0 + (tabsNeedSecondRow ? Self.tabRowStep : 0)
    }
    
    /// Width kept free for the camera housing in the tab band (none on a display without a notch)
    public var tabCutoutWidth: CGFloat {
        notchInfo.hasPhysicalNotch ? idleWidth + 2 * Self.cutoutMargin : 0
    }
    
    /// Tabs go left of the camera, then right of it; a second row only when both sides are full. Sized for every tab
    /// as an icon plus the widest title, so selecting another tab never moves one between rows.
    public var tabsNeedSecondRow: Bool {
        guard notchInfo.hasPhysicalNotch else { return false }
        let font = NSFont.systemFont(ofSize: 10.8, weight: .bold)
        let widestTitle = visibleTabs.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let icon: CGFloat = 28, spacing: CGFloat = 6
        let needed = CGFloat(visibleTabs.count) * (icon + spacing) + widestTitle + 11
        let side = (Self.openWidth - 28 - tabCutoutWidth) / 2
        // a tab never straddles the camera, so up to one tab's width is lost at the left side's end
        return needed > 2 * side - (icon + widestTitle + 11)
    }
    
    // External monitor display settings computed flags
    public var isNotchCompletelyDisabled: Bool {
        notchInfo.isExternalDisplay &&
        SettingsService.shared.disableOnExternalDisplays &&
        !SettingsService.shared.revealOnHoverOnExternalDisplays
    }
    
    public var isNotchHiddenInIdleOnExternal: Bool {
        notchInfo.isExternalDisplay &&
        SettingsService.shared.disableOnExternalDisplays &&
        SettingsService.shared.revealOnHoverOnExternalDisplays
    }
    
    // Visual expansion horizontally happens on hover OR temporary 2s event pulse OR persistent confirmation alert OR active screen recording
    public var isVisuallyExpanded: Bool {
        if isNotchCompletelyDisabled { return false }
        if isNotchHiddenInIdleOnExternal && !isHovered { return false }
        return isHovered || isTemporaryWingExpanded || isWaitingConfirmation || isRecordingScreen
    }
    
    // Horizontal wing width (ears) extending beyond physical notch
    public var wingWidth: CGFloat {
        max(0, (currentWidth - idleWidth) / 2.0)
    }
    
    // Width expands horizontally whenever hovered OR when 2-second pulse is active
    public var currentWidth: CGFloat {
        isVisuallyExpanded ? expandedWidth : idleWidth
    }
    
    // Height expands DOWNWARDS ONLY WHEN HOVERED!
    // When unhovered, it NEVER expands downwards under any circumstances.
    public var currentHeight: CGFloat {
        isHovered ? expandedHeight : idleHeight
    }
    
    public var currentCornerRadius: CGFloat {
        isHovered ? 22.0 : 11.0
    }
    
    // Window frame in screen coordinates
    public var windowFrame: NSRect {
        let x = notchInfo.notchRect.midX - (windowWidth / 2.0)
        let y = notchInfo.screenFrame.maxY - windowHeight
        return NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
    }
    
    /// While files are dragged to the open notch, the format ring around it must stay inside the hit and hover area.
    public var isFormatRingVisible: Bool { isHovered && isFormatRingPresent }
    /// The ring is in the view tree while a drag is in progress, so it can open and close in the same transaction as the card.
    public var isFormatRingPresent: Bool { !draggedFiles.isEmpty && !conversionTargets.isEmpty }
    
    // Rect of the active pill in window coordinates (AppKit: origin at bottom-left)
    public var activePillRectInWindow: NSRect {
        if isIntroHidden || isNotchCompletelyDisabled || (isNotchHiddenInIdleOnExternal && !isHovered) {
            return .zero
        }
        let w = isFormatRingVisible ? windowWidth : currentWidth
        let h = isFormatRingVisible ? max(currentHeight, ConversionPetalRing.bottom) : currentHeight
        let x = (windowWidth - w) / 2.0
        let y = windowHeight - h
        return NSRect(x: x, y: y, width: w, height: h)
    }
    
    // Active pill rect in screen coordinates (matches NSEvent.mouseLocation)
    public var currentPillRectOnScreen: CGRect {
        let w = isFormatRingVisible ? windowWidth : currentWidth
        let h = isFormatRingVisible ? max(currentHeight, ConversionPetalRing.bottom) : currentHeight
        let x = notchInfo.notchRect.midX - (w / 2.0)
        let y = notchInfo.screenFrame.maxY - h
        return CGRect(x: x, y: y, width: w, height: h)
    }
    
    // MARK: - Trackpad Tab Navigation & Swipe Handling
    
    private var accumulatedDeltaX: CGFloat = 0.0
    private var lastSwitchTime: Date = .distantPast
    private let switchThreshold: CGFloat = 28.0
    private let switchDebounce: TimeInterval = 0.32
    
    public func switchToNextTab() {
        let all = visibleTabs
        guard let idx = all.firstIndex(of: selectedTab) else { return }
        let nextIdx = min(all.count - 1, idx + 1)
        if nextIdx != idx {
            withAnimation(Self.springAnimation) {
                self.selectedTab = all[nextIdx]
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }
    }
    
    public func switchToPreviousTab() {
        let all = visibleTabs
        guard let idx = all.firstIndex(of: selectedTab) else { return }
        let prevIdx = max(0, idx - 1)
        if prevIdx != idx {
            withAnimation(Self.springAnimation) {
                self.selectedTab = all[prevIdx]
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }
    }
    
    /// Mouse side buttons over the open notch: back (3) = next tab, forward (4) = previous tab
    @discardableResult
    public func handleSideButton(_ event: NSEvent) -> Bool {
        guard isHovered, SettingsService.shared.mouseSideButtonsTabs else { return false }
        switch event.buttonNumber {
        case 3: switchToNextTab()
        case 4: switchToPreviousTab()
        default: return false
        }
        return true
    }

    @discardableResult
    public func handleScrollWheel(_ event: NSEvent) -> Bool {
        guard isHovered, currentPillRectOnScreen.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) else {
            accumulatedDeltaX = 0
            return false
        }
        
        // Ignore momentum scrolling phases so tab switching only responds to active finger contact
        if !event.momentumPhase.isEmpty {
            accumulatedDeltaX = 0
            return false
        }
        
        // Reset when user lifts fingers or cancels gesture
        if event.phase == .ended || event.phase == .cancelled {
            accumulatedDeltaX = 0
            return false
        }
        
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX * 12
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 12
        
        // If movement is predominantly vertical, let it pass to vertical ScrollViews (e.g. Clipboard)
        if abs(dy) >= abs(dx) * 1.15 || abs(dx) < 1.0 {
            accumulatedDeltaX = 0
            return false
        }
        
        accumulatedDeltaX += dx
        
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSwitchTime)
        
        if abs(accumulatedDeltaX) >= switchThreshold && elapsed >= switchDebounce {
            lastSwitchTime = now
            let isNext = accumulatedDeltaX < 0
            accumulatedDeltaX = 0
            
            DispatchQueue.main.async { [weak self] in
                if isNext {
                    self?.switchToNextTab()
                } else {
                    self?.switchToPreviousTab()
                }
            }
            return true
        }
        
        // Consume horizontal deltas during active gesture to prevent conflicting subview horizontal scrolling
        return true
    }
    
    @discardableResult
    public func handleSwipe(_ event: NSEvent) -> Bool {
        guard isHovered, currentPillRectOnScreen.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) else {
            return false
        }
        
        let now = Date()
        if now.timeIntervalSince(lastSwitchTime) < switchDebounce {
            return true
        }
        
        if event.deltaX < -0.1 {
            lastSwitchTime = now
            accumulatedDeltaX = 0
            DispatchQueue.main.async { [weak self] in
                self?.switchToNextTab()
            }
            return true
        } else if event.deltaX > 0.1 {
            lastSwitchTime = now
            accumulatedDeltaX = 0
            DispatchQueue.main.async { [weak self] in
                self?.switchToPreviousTab()
            }
            return true
        }
        return false
    }
}


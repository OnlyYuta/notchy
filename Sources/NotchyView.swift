import SwiftUI
import UniformTypeIdentifiers

public struct NotchyView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var l10n = LocalizationService.shared
    
    private let spring = NotchViewModel.springAnimation
    @State private var dropTargeted = false
    @State private var tabCenters: [String: ClosedRange<CGFloat>] = [:]
    @State private var tabHoverX: CGFloat?
    @State private var draggingTab: ExpandedTab?
    @State private var tabDragX: CGFloat = 0
    @State private var dragSlot: Int?
    
    public init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        ZStack(alignment: .top) {
            // Invisible anchor matching window size
            Color.clear
                .frame(width: viewModel.windowWidth, height: viewModel.windowHeight)
            
            // The Notchy: 100% pure pitch black OLED background
            // The silhouette, its shadow and the clip are Core Animation layers (NotchShellView): only content lives here,
            // laid out at its final size at once, so SwiftUI does no work per frame while the notch springs open or shut
            ZStack(alignment: .top) {
                // 1. Compact Horizontal Wings Mode (Unhovered)
                // Height stays strictly idleHeight (32 pt), expanding only sideways
                HStack(spacing: 0) {
                    // Left wing (Agent logo(s), Music Album Artwork, or Recording badge)
                    ZStack {
                        if viewModel.temporaryMode == .replaySaved {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundColor(.green)
                        } else if viewModel.isRecordingScreen {
                            RecordingDot(paused: viewModel.isHovered)
                        } else if uniqueWorkingAgents.count >= 2 && viewModel.workState != .idle {
                            let maxVisible = 3
                            let displayAgents = Array(uniqueWorkingAgents.prefix(maxVisible))
                            let remaining = uniqueWorkingAgents.count - maxVisible
                            HStack(spacing: 3) {
                                ForEach(displayAgents, id: \.self) { agent in
                                    AgentBadgeView(agent: agent, size: 13.5, isPulsing: wingAnimating)
                                }
                                if remaining > 0 {
                                    Text("+\(remaining)")
                                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                        .foregroundColor(.white.opacity(0.85))
                                        .padding(.horizontal, 3)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(Color.white.opacity(0.2)))
                                }
                            }
                            .opacity(viewModel.activeMode == .agent && !viewModel.isHovered ? 1.0 : 0.0)
                            .scaleEffect(viewModel.activeMode == .agent ? 1.0 : 0.5)
                            .animation(spring, value: viewModel.activeMode)
                            .animation(spring, value: viewModel.workState)
                            .animation(spring, value: displayAgents)
                        } else {
                            AgentBadgeView(agent: viewModel.currentAgent, size: 14.5, isPulsing: wingAnimating)
                                .opacity(viewModel.activeMode == .agent && !viewModel.isHovered ? 1.0 : 0.0)
                                .scaleEffect(viewModel.activeMode == .agent ? 1.0 : 0.5)
                                .animation(spring, value: viewModel.activeMode)
                                .animation(spring, value: viewModel.workState)
                                .animation(spring, value: viewModel.currentAgent)
                        }
                        
                        // Music Artwork
                        TrackArtworkView(image: viewModel.currentTrack?.artwork, size: 16.0)
                            .id(viewModel.currentTrack?.title ?? "")
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.3), value: viewModel.currentTrack?.title)
                            .opacity(viewModel.activeMode == .music && !viewModel.isHovered ? 1.0 : 0.0)
                            .scaleEffect(viewModel.activeMode == .music ? 1.0 : 0.5)
                            .animation(spring, value: viewModel.activeMode)
                    }
                    .frame(width: viewModel.wingWidth, height: viewModel.idleHeight)
                    .clipped()
                    
                    // Center (hardware notch cutout area)
                    Color.clear
                        .frame(width: viewModel.idleWidth, height: viewModel.idleHeight)
                    
                    // Right wing (Status indicator, Replay Bolt, or 5-bar Music Visualizer)
                    ZStack {
                        if viewModel.temporaryMode == .replaySaved {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundColor(.yellow)
                        } else if viewModel.isRecordingScreen {
                            RecordingTimer()
                        } else if viewModel.activeMode == .agent && !viewModel.isHovered {
                            // Thinking / Working (3 dots)
                            if wingAnimating {
                                ThreeDotsView()
                                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                            }
                            
                            // Prompt received (yellow bolt)
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 13.0, weight: .bold))
                                .foregroundColor(Color.yellow)
                                .opacity(viewModel.workState == .promptReceived ? 1.0 : 0.0)
                                .scaleEffect(viewModel.workState == .promptReceived ? 1.0 : 0.5)
                                .animation(spring, value: viewModel.workState)
                            
                            // Needs confirmation (Yellow exclamation mark in circle)
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.0))
                                .opacity(viewModel.workState == .needsConfirmation ? 1.0 : 0.0)
                                .scaleEffect(viewModel.workState == .needsConfirmation ? 1.0 : 0.5)
                                .animation(spring, value: viewModel.workState)
                            
                            // Done badge: mounted only while done so the check redraws every time
                            if viewModel.workState == .done {
                                AnimatedCheckView(size: 14.0, color: Color(red: 0.20, green: 0.85, blue: 0.40))
                                    .transition(.asymmetric(
                                        insertion: .opacity,
                                        removal: .scale(scale: 0.3).combined(with: .opacity)
                                    ))
                            }
                        } else if viewModel.activeMode == .music && !viewModel.isHovered {
                            // 5-bar live audio equalizer
                            MusicVisualizerView(isPlaying: viewModel.isMusicPlaying && !viewModel.isHovered && viewModel.activeMode == .music, barCount: 5)
                                .opacity(viewModel.activeMode == .music ? 1.0 : 0.0)
                                .scaleEffect(viewModel.activeMode == .music ? 1.0 : 0.5)
                                .animation(spring, value: viewModel.activeMode)
                        }
                    }
                    .frame(width: viewModel.wingWidth, height: viewModel.idleHeight)
                    .clipped()
                    .animation(.easeInOut(duration: 0.45), value: viewModel.workState)
                }
                .frame(width: viewModel.currentWidth, height: viewModel.idleHeight)
                // Hiding on hover is quick; the fade-in on the way back follows the notch's own animated width (next modifier),
                // so the quick animation must stay below it
                // jumps to its final width: the shell's mask reveals it as the notch grows
                .animation(nil, value: viewModel.currentWidth)
                .opacity(viewModel.isHovered ? 0 : 1)
                .animation(.easeOut(duration: 0.12), value: viewModel.isHovered)
                .allowsHitTesting(!viewModel.isHovered)
                
                // 2. Full Expanded Card Mode (Hovered)
                // Downward expansion to dynamic expandedHeight, strictly when hovered
                // Built once and kept: opening only fades it in, instead of building the whole tab tree in the first frames
                Group {
                    VStack(spacing: 0) {
                        // Tabs in the band beside the camera (left, then right of it), a second row only when both are full
                        NotchTabBarLayout(cutout: viewModel.tabCutoutWidth, bandHeight: viewModel.tabBandHeight) {
                            ForEach(viewModel.visibleTabs) { tab in
                                NotchTabButton(
                                    title: tab.title,
                                    icon: tab.icon,
                                    isSelected: viewModel.selectedTab == tab
                                ) {
                                    withAnimation(spring) {
                                        viewModel.selectedTab = tab
                                    }
                                }
                                // Dock-style magnification: measured unscaled, so the swell never moves the layout
                                .background(GeometryReader { geo in
                                    Color.clear.preference(key: TabCentersKey.self, value: [tab.rawValue: geo.frame(in: .named("tabRow")).minX...geo.frame(in: .named("tabRow")).maxX])
                                })
                                .scaleEffect(1 + 0.42 * tabInfluence(tab), anchor: .center)
                                .offset(x: draggingTab == tab ? tabDragX : tabShift(tab))
                                .zIndex(draggingTab == tab ? 10 : tabInfluence(tab))
                                .opacity(draggingTab == tab ? 0.85 : 1)
                                .simultaneousGesture(tab == .settings ? nil : reorderGesture(tab))
                            }
                        }
                        .frame(width: NotchViewModel.openWidth - 28,
                               height: viewModel.tabBandHeight + (viewModel.tabsNeedSecondRow ? NotchViewModel.tabRowStep : 0),
                               alignment: .topLeading)
                        .coordinateSpace(name: "tabRow")
                        .onPreferenceChange(TabCentersKey.self) { tabCenters = $0 }
                        .onContinuousHover(coordinateSpace: .named("tabRow")) { phase in
                            switch phase {
                            case .active(let point): tabHoverX = point.x
                            case .ended: tabHoverX = nil
                            }
                        }
                        .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.72), value: tabHoverX)
                        .padding(.horizontal, 14)
                        .animation(NotchViewModel.snappyAnimation, value: viewModel.selectedTab)
                        .animation(spring, value: viewModel.visibleTabs)
                        
                        // Tab Content Area (not built while files are dragged: it would keep animating behind the drop zone)
                        Group {
                        if !viewModel.draggedFiles.isEmpty {
                            Color.clear
                        } else {
                        switch viewModel.selectedTab {
                        case .music:
                            MusicTabView(viewModel: viewModel)
                            
                        case .record:
                            // SCREEN RECORD & REPLAY TAB
                            RecordTabView()
                            
                        case .clipboard:
                            // CLIPBOARD TAB
                            ClipboardTabView()
                            
                        case .settings:
                            // SETTINGS TAB
                            SettingsTabView()
                            
                        case .agents:
                            // AGENTS TAB: Vertical Column (Столбик)
                            let instances = viewModel.agentRows
                            Group {
                            if instances.count == 1 {
                                // One agent: a single large card fills the whole area
                                AgentRowView(instance: instances[0], fill: true)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 6)
                                    .padding(.bottom, 14)
                                    .frame(maxHeight: .infinity)
                            } else {
                                // Two agents fit exactly; the third and further ones scroll
                                ScrollView(.vertical, showsIndicators: false) {
                                    VStack(spacing: 7) {
                                        // Keyed by agent when unique, so a row that goes done -> idle keeps its view
                                        // and only its status animates instead of the whole row being swapped
                                        let unique = Set(instances.map(\.agent)).count == instances.count
                                        ForEach(instances.map { AgentRowItem(key: unique ? $0.agent.rawValue : $0.id, instance: $0) }) { item in
                                            AgentRowView(instance: item.instance, medium: true)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .padding(.horizontal, 14)
                                .padding(.top, 6)
                                .padding(.bottom, 14)
                                .frame(maxHeight: .infinity)
                            }
                            }
                            // Rows are added/removed from several publishers, some unanimated: animate here so a finished row never just vanishes
                            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: instances)
                        }
                        }
                        }
                        .id(viewModel.selectedTab)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        .animation(spring, value: viewModel.selectedTab)
                    }
                    // Laid out once at the open size: the growing notch shape reveals still content instead of
                    // dragging it (and re-centring it) through every frame of the animation
                    .frame(width: NotchViewModel.openWidth, height: viewModel.expandedHeight)
                    .overlay(dropOverlay)
                    .overlay(alignment: .bottom) { ConversionToast() }
                    .onDrop(of: [.fileURL, .image, .url, .plainText], isTargeted: $dropTargeted) { providers in
                        handleDrop(providers)
                    }
                    // Comes into focus as the card grows, blurs away as it closes
                    .modifier(CardBlurOut(amount: viewModel.isHovered ? 0 : 1))
                    .animation(viewModel.isHovered ? .easeOut(duration: 0.3) : .easeInOut(duration: 0.25), value: viewModel.isHovered)
                    .allowsHitTesting(viewModel.isHovered)
                }
            }
            .frame(width: viewModel.windowWidth, height: viewModel.windowHeight, alignment: .top)
            .offset(y: isHiddenOnExternal ? -(viewModel.expandedHeight + 15) : 0)
            .opacity(isHiddenOnExternal ? 0.0 : 1.0)
            .animation(spring, value: isHiddenOnExternal)
            // Exists only during the first-launch sweep: otherwise its outline would be re-stroked on every frame
            .overlay {
                if viewModel.introGlow {
                    IntroGlowRing(active: true, bottomRadius: viewModel.currentCornerRadius)
                        .frame(width: viewModel.currentWidth, height: viewModel.currentHeight)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                }
            }
            // First launch: squeezed and lifted out of sight, then it springs to its place with an overshoot
            .scaleEffect(x: viewModel.isIntroHidden ? 0.3 : 1, y: viewModel.isIntroHidden ? 0.45 : 1, anchor: .top)
            .offset(y: viewModel.isIntroHidden ? -26 : 0)
            .opacity(viewModel.isIntroHidden ? 0 : 1)
            
            // Format petals fanned around the outside of the notch while files are dragged to it
            if viewModel.isFormatRingPresent {
                // The ring is laid out for the open card and then scaled and faded by the card's real, animated width, so it
                // opens and closes exactly with the card instead of running its own animation
                let openWidth = NotchViewModel.openWidth
                ConversionPetalRing(
                    targets: viewModel.conversionTargets,
                    files: viewModel.draggedFiles,
                    size: CGSize(width: viewModel.windowWidth, height: viewModel.windowHeight),
                    cardSize: CGSize(width: openWidth, height: viewModel.expandedHeight)
                )
                .compositingGroup()
                .modifier(FollowCardWidth(width: viewModel.currentWidth, openWidth: openWidth, idleWidth: viewModel.idleWidth))
                .allowsHitTesting(viewModel.isHovered)
            }
        }
        .frame(width: viewModel.windowWidth, height: viewModel.windowHeight, alignment: .top)
    }
    
    /// The wing animations (pulsing glow, dots) run on a display-rate timeline, so they must exist only while the wing
    /// is actually visible: expanded but not hovered. Otherwise they redraw SwiftUI 24-30x/s behind a zero-width clip.
    private var wingAnimating: Bool {
        viewModel.workState == .working && viewModel.isVisuallyExpanded && !viewModel.isHovered
    }
    
    /// Only the tab under the cursor swells (1); the others, and the tab that is already open, stay put (0)
    /// Hold, then drag a tab; it follows the cursor and takes the slot it is dropped on.
    private func reorderGesture(_ tab: ExpandedTab) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("tabRow")))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if draggingTab != tab {
                    draggingTab = tab
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                }
                tabDragX = drag.translation.width
                let others = reorderable(excluding: tab)
                let slot = others.filter { o in tabCenters[o.rawValue].map { ($0.lowerBound + $0.upperBound) / 2 < drag.location.x } ?? false }.count
                if slot != dragSlot { withAnimation(spring) { dragSlot = slot } }
            }
            .onEnded { _ in
                if let slot = dragSlot {
                    let settings = SettingsService.shared
                    let others = reorderable(excluding: tab)
                    settings.tabOrder.removeAll { $0 == tab }
                    let at = slot < others.count ? settings.tabOrder.firstIndex(of: others[slot]) : others.last.flatMap { settings.tabOrder.firstIndex(of: $0) }.map { $0 + 1 }
                    settings.tabOrder.insert(tab, at: at ?? settings.tabOrder.count)
                }
                withAnimation(spring) { draggingTab = nil; tabDragX = 0; dragSlot = nil }
            }
    }
    
    /// Tabs between the dragged one and the drop slot slide aside to open a gap.
    private func reorderable(excluding tab: ExpandedTab) -> [ExpandedTab] {
        viewModel.visibleTabs.filter { $0 != tab && $0 != .settings }
    }
    
    private func tabShift(_ tab: ExpandedTab) -> CGFloat {
        guard let drag = draggingTab, let slot = dragSlot, let span = tabCenters[drag.rawValue],
              let i = viewModel.visibleTabs.firstIndex(of: tab), let from = viewModel.visibleTabs.firstIndex(of: drag) else { return 0 }
        let w = span.upperBound - span.lowerBound + 6
        if i < from, i >= slot { return w }
        if i > from, i - 1 < slot { return -w }
        return 0
    }
    
    private func tabInfluence(_ tab: ExpandedTab) -> CGFloat {
        guard tab != viewModel.selectedTab, draggingTab == nil, let x = tabHoverX, let span = tabCenters[tab.rawValue] else { return 0 }
        return (span.lowerBound - 3...span.upperBound + 3).contains(x) ? 1 : 0
    }
    
    // MARK: - Drop to clipboard
    
    /// Shown while something is dragged over the open notch.
    @ViewBuilder
    private var dropOverlay: some View {
        if !viewModel.draggedFiles.isEmpty {
            ConversionCenterZone(centerTargeted: dropTargeted, topInset: viewModel.tabBandHeight + 4)
        } else if dropTargeted {
            let ru = l10n.currentLanguage == .ru
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.78))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 24, weight: .semibold))
                    Text(tr("Отпустите, чтобы сохранить в буфер", "Drop to save to the clipboard"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundColor(.white)
            }
            .padding(EdgeInsets(top: viewModel.tabBandHeight + 4, leading: 10, bottom: 10, trailing: 10))
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
    
    /// Files and folders are kept by reference; an image with no file behind it is saved as PNG; web links and text as text.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let clipboard = ClipboardService.shared
        var fileURLs: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        var imageData: Data?
        var texts: [String] = []
        
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let u = item as? URL { url = u }
                    lock.lock(); if let url = url { fileURLs.append(url) }; lock.unlock()
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    lock.lock(); if imageData == nil { imageData = data }; lock.unlock()
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    lock.lock(); if let url = url { texts.append(url.absoluteString) }; lock.unlock()
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                group.enter()
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    lock.lock(); if let string = string { texts.append(string) }; lock.unlock()
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) {
            if !fileURLs.isEmpty { clipboard.add(files: fileURLs) }
            else if let data = imageData { clipboard.add(imageData: data) }
            else { texts.forEach { clipboard.add(text: $0) } }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
            withAnimation(spring) { viewModel.selectedTab = .clipboard }
        }
        return true
    }
    
    private var isHiddenOnExternal: Bool {
        viewModel.isNotchCompletelyDisabled || (viewModel.isNotchHiddenInIdleOnExternal && !viewModel.isHovered)
    }
    
    private var uniqueWorkingAgents: [AgentType] {
        var seen = Set<AgentType>()
        var list: [AgentType] = []
        for inst in viewModel.workingInstances {
            if !seen.contains(inst.agent) {
                seen.insert(inst.agent)
                list.append(inst.agent)
            }
        }
        return list
    }
}

// MARK: - Agent Row in Vertical Column

struct AgentRowItem: Identifiable {
    let key: String
    let instance: AgentInstance
    var id: String { key }
}

struct AgentRowView: View {
    let instance: AgentInstance
    /// Large card that stretches to the available height (used when only one or two agents are listed)
    var fill: Bool = false
    /// Two-line card sized so that two agents fit the card without scrolling
    var medium: Bool = false
    private var rich: Bool { fill || medium }
    
    private var subtitle: String {
        if let d = instance.statusDescription, !d.isEmpty { return d }
        switch instance.workState {
        case .idle:
            if medium { return tr("Открыт · ждёт задачу", "Open · waiting for a task") }
            return tr("Открыт · ждёт задачу · нажмите, чтобы открыть", "Open · waiting for a task · click to open")
        case .promptReceived, .working: return tr("Выполняет задачу", "Working on a task")
        case .needsConfirmation: return tr("Нужно ваше подтверждение", "Needs your confirmation")
        case .done: return tr("Задача завершена", "Task finished")
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 9) {
                // Agent Logo
                AgentBadgeView(agent: instance.agent, size: fill ? 30.0 : (medium ? 24.0 : 22.0), isPulsing: instance.workState == .working)
                
                // Name + Project pill
                VStack(alignment: .leading, spacing: medium ? 1 : 4) {
                HStack(spacing: 6) {
                    Text(instance.agent.displayName)
                        .font(.system(size: 12.0, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    if !instance.projectName.isEmpty {
                        Text(instance.projectName)
                            .font(.system(size: 10.0, weight: .semibold, design: .monospaced))
                            .foregroundColor(instance.agent.accentColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 130)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(instance.agent.accentColor.opacity(0.18))
                            )
                    }
                }
                
                if rich {
                    Text(subtitle)
                        .font(.system(size: medium ? 9.5 : 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
                }
                
                Spacer()
                
                // Status Indicator: old and new status overlap and cross-fade instead of snapping
                ZStack(alignment: .trailing) {
                HStack(spacing: 4.5) {
                    switch instance.workState {
                    case .idle:
                        Circle()
                            .fill(Color.white.opacity(0.40))
                            .frame(width: 4.5, height: 4.5)
                        Text(LocalizationService.shared.t(.agentStatusIdle))
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.65))
                    case .promptReceived:
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9.0, weight: .bold))
                            .foregroundColor(instance.agent.accentColor)
                        Text(LocalizationService.shared.t(.agentStatusPromptReceived))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(instance.agent.accentColor)
                    case .working:
                        HStack(spacing: 4.5) {
                            Text(LocalizationService.shared.t(.agentStatusWorking))
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                            ThreeDotsView()
                        }
                    case .needsConfirmation:
                        HStack(spacing: 4.0) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 10.5, weight: .bold))
                            Text(LocalizationService.shared.t(.agentStatusConfirmation))
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.0))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color(red: 1.0, green: 0.82, blue: 0.0).opacity(0.18))
                        )
                    case .done:
                        Button(action: {
                            AgentStatusService.shared.dismissInstance(id: instance.id)
                        }) {
                            HStack(spacing: 4.0) {
                                AnimatedCheckView(size: 14.0, color: Color(red: 0.20, green: 0.85, blue: 0.40))
                                Image(systemName: "xmark")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .opacity(0.60)
                            }
                            .foregroundColor(Color(red: 0.20, green: 0.85, blue: 0.40))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color(red: 0.20, green: 0.85, blue: 0.40).opacity(0.18))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .foregroundColor(instance.workState == .done ? Color(red: 0.20, green: 0.85, blue: 0.40) : (instance.workState == .needsConfirmation ? Color(red: 1.0, green: 0.82, blue: 0.0) : .white))
                .id(instance.workState)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.6, anchor: .trailing).combined(with: .opacity),
                    removal: .scale(scale: 0.85, anchor: .trailing).combined(with: .opacity)
                ))
                }
                .animation(.spring(response: 0.5, dampingFraction: 0.78), value: instance.workState)
            }
            .frame(height: fill ? nil : (medium ? 30.0 : 26.0))
            
            if instance.subagentCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.35))
                    Text("\(instance.subagentCount) \(LocalizationService.shared.t(.subagentsWorking))")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundColor(instance.agent.accentColor.opacity(0.85))
                    ThreeDotsView()
                        .scaleEffect(0.7)
                        .colorMultiply(instance.agent.accentColor)
                }
                .padding(.leading, 31)
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, fill ? 14 : (medium ? 10 : 8))
        .padding(.vertical, fill ? 8 : 4)
        .frame(maxHeight: fill ? .infinity : nil)
        .background(
            RoundedRectangle(cornerRadius: 11.0, style: .continuous)
                .fill(rich
                      ? AnyShapeStyle(LinearGradient(colors: [instance.agent.accentColor.opacity(0.22), instance.agent.accentColor.opacity(0.04)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                      : AnyShapeStyle(Color.white.opacity(0.06)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11.0, style: .continuous)
                .stroke(instance.workState == .needsConfirmation ? Color(red: 1.0, green: 0.82, blue: 0.0).opacity(0.4) : Color.white.opacity(0.06), lineWidth: 0.8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let running = NSWorkspace.shared.runningApplications
            let target = running.first { instance.agent.matches(bundleId: $0.bundleIdentifier, name: $0.localizedName) }
            // openApplication brings the app forward reliably; activate() is ignored by recent macOS for a background app
            if let url = (target ?? AgentStatusService.shared.cliHostApp(for: instance.agent))?.bundleURL {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }
}


// MARK: - Reusable UI Components

/// Lays the tabs out in the notch band: left of the camera, then right of it, then a second row under the band.
/// Rows are vertically centred in the band (and in the second row), so the tabs line up with the menu bar.
struct NotchTabBarLayout: Layout {
    let cutout: CGFloat
    let bandHeight: CGFloat
    var spacing: CGFloat = 6
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = bounds.width
        let gapStart = (w - cutout) / 2, gapEnd = (w + cutout) / 2
        var x: CGFloat = 0, row = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if row == 0 && cutout > 0 && x < gapEnd && x + size.width > gapStart { x = gapEnd }
            if x + size.width > w && x > 0 { row += 1; x = 0 }
            let midY = row == 0 ? bandHeight / 2 : bandHeight + CGFloat(row - 1) * NotchViewModel.tabRowStep + NotchViewModel.tabRowStep / 2
            sub.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + midY), anchor: .leading, proposal: .unspecified)
            x += size.width + spacing
        }
    }
}

struct NotchTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5.0) {
                Image(systemName: icon)
                    // Рисуем в 1.42× и уменьшаем: при увеличении в доке иконка остаётся чёткой, а не растянутой
                    .font(.system(size: (isSelected ? 9.5 : 10.0) * 1.42, weight: isSelected ? .bold : .semibold))
                    .frame(width: 14 * 1.42, height: 14 * 1.42)
                    .scaleEffect(1 / 1.42)
                    .frame(width: 14, height: 14)
                
                if isSelected {
                    Text(title)
                        .font(.system(size: 10.8, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                }
            }
            .foregroundColor(isSelected ? .white : Color.white.opacity(0.60))
            .padding(.horizontal, isSelected ? 10.0 : 7.0)
            .frame(height: 24.0)
            .background(
                Capsule()
                    .fill(isSelected ? Color.white.opacity(0.22) : Color.white.opacity(0.07))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isSelected ? 0.16 : 0.0), lineWidth: 0.6)
            )
            .contentShape(Capsule())
            .animation(NotchViewModel.springAnimation, value: isSelected)
        }
        .buttonStyle(NotchPressButtonStyle())
    }
}

struct NotchIconButton: View {
    let icon: String
    let size: CGFloat
    var iconOffset: CGFloat = 0.0
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.16))
                    .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.6))
                    .frame(width: size, height: size)
                Image(systemName: icon)
                    .font(.system(size: size * 0.40, weight: .bold))
                    .foregroundColor(.white)
                    .offset(x: iconOffset)
            }
        }
        .buttonStyle(NotchPressButtonStyle())
    }
}

struct NotchPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}


// MARK: - Music Tab

struct MusicTabView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var l10n = LocalizationService.shared
    
    @ObservedObject private var nowPlaying = NowPlayingService.shared
    
    private var track: TrackInfo? { viewModel.currentTrack }
    private var playing: Bool { viewModel.isMusicPlaying }
    // Slide only when the track itself changes. The cover image object is re-created on every poll for some
    // players, so keying on it made the artwork slide constantly.
    private var trackKey: String { "\(track?.title ?? "")|\(track?.artist ?? "")" }
    private var artworkKey: String { trackKey }
    
    var body: some View {
        VStack(spacing: 7) {
        HStack(spacing: 16) {
            ZStack {
                TrackArtworkView(image: track?.artwork, size: 72.0)
                    .id(artworkKey)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            .frame(width: 72, height: 72)
            .clipped()
            .scaleEffect(playing ? 1.0 : 0.94)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: playing)
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: artworkKey)
            
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                
                // Old and new text overlap in a ZStack so the row doesn't jump while they cross-fade
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(track?.title ?? (playing ? l10n.t(.musicPlaying) : l10n.t(.musicNoTrack)))
                            .font(.system(size: 15.0, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        let artist = track?.artist ?? ""
                        Text(!artist.isEmpty ? artist : (playing ? l10n.t(.musicAudioPlayer) : l10n.t(.musicPaused)))
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                            .padding(.top, 3)
                    }
                    .id(trackKey)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                }
                .clipped()
                .animation(.spring(response: 0.45, dampingFraction: 0.86), value: trackKey)
                
                Spacer(minLength: 6)
                
                HStack(spacing: 10) {
                    NotchIconButton(icon: "backward.fill", size: 28.0) {
                        NowPlayingService.shared.previousTrack()
                    }
                    .help(l10n.t(.musicPrevious))
                    
                    Button(action: { NowPlayingService.shared.togglePlayPause() }) {
                        ZStack {
                            Circle().fill(Color.white)
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.black)
                                .offset(x: playing ? 0 : 1.2)
                        }
                        .frame(width: 34, height: 34)
                    }
                    .buttonStyle(NotchPressButtonStyle())
                    .help(l10n.t(.musicPlayPause))
                    
                    NotchIconButton(icon: "forward.fill", size: 28.0) {
                        NowPlayingService.shared.nextTrack()
                    }
                    .help(l10n.t(.musicNext))
                    
                    Spacer(minLength: 0)
                    
                    MusicVisualizerView(isPlaying: playing && viewModel.isHovered && viewModel.selectedTab == .music, barCount: 5, accentColor: .white)
                        .scaleEffect(1.3)
                }
                
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        
        if let timeline = nowPlaying.timeline {
            TrackTimelineView(timeline: timeline, playing: playing)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        }
        .animation(NotchViewModel.springAnimation, value: nowPlaying.timeline != nil)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Track Timeline

struct TrackTimelineView: View {
    let timeline: TrackTimeline
    let playing: Bool
    
    var body: some View {
        // Paused schedule = no redraws while the track is paused
        TimelineView(.animation(minimumInterval: 0.25, paused: !playing)) { context in
            let pos = timeline.position(at: context.date)
            HStack(spacing: 8) {
                Text(Self.format(pos))
                    .frame(width: 34, alignment: .trailing)
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(Color.white)
                            .frame(width: geo.size.width * CGFloat(pos / max(timeline.duration, 1)))
                    }
                }
                .frame(height: 3.5)
                
                Text(Self.format(timeline.duration))
                    .frame(width: 34, alignment: .leading)
            }
            .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundColor(.white.opacity(0.55))
        }
        .frame(height: 12)
    }
    
    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}


private struct TabCentersKey: PreferenceKey {
    static var defaultValue: [String: ClosedRange<CGFloat>] = [:]
    static func reduce(value: inout [String: ClosedRange<CGFloat>], nextValue: () -> [String: ClosedRange<CGFloat>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Opacity of the wing contents follows the notch's animated width: invisible while it is still wider than the resting wings,
/// fully visible once it has settled.

/// Scales and fades a view by the card's width. The width is animatable data, so it is interpolated by the very same
/// transaction (and spring) that animates the card's frame: the two always move together.
private struct FollowCardWidth: AnimatableModifier {
    var width: CGFloat
    let openWidth: CGFloat
    let idleWidth: CGFloat
    
    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }
    
    func body(content: Content) -> some View {
        let live = min(max(width, 1), openWidth)
        let progress = min(max((live - idleWidth) / max(openWidth - idleWidth, 1), 0), 1)
        content
            .scaleEffect(live / openWidth, anchor: .top)
            .opacity(progress)
    }
}

// MARK: - Recording indicator (left and right wing)

/// Red record dot with a soft ring that pulses outward, like a camera's tally light.
private struct RecordingDot: View {
    var paused = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
            ZStack {
                // The ring stays inside the 18 pt box: grown from the dot's size to just under the edge
                Circle()
                    .stroke(Color.red.opacity(0.6 * (1 - phase)), lineWidth: 1.2)
                    .frame(width: 9, height: 9)
                    .scaleEffect(1 + 0.85 * phase)
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1.0, green: 0.42, blue: 0.40), Color(red: 0.9, green: 0.1, blue: 0.12)],
                                         center: .topLeading, startRadius: 0, endRadius: 8))
                    .frame(width: 9, height: 9)
                    .shadow(color: Color.red.opacity(0.75), radius: 3)
            }
            .frame(width: 18, height: 18)
        }
    }
}

/// Elapsed time on one line; observes the recorder itself so it keeps ticking.
private struct RecordingTimer: View {
    @ObservedObject private var recorder = ScreenRecorderService.shared
    
    var body: some View {
        Text(recorder.recordingDurationText)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Animated Checkmark

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.53))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.71))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.77, y: rect.minY + rect.height * 0.32))
        return p
    }
}

/// Green disc that springs in, then the tick draws itself, then a soft ring ripples out.
struct AnimatedCheckView: View {
    let size: CGFloat
    let color: Color
    @State private var shown = false
    @State private var rippled = false
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(rippled ? 0.0 : 0.55), lineWidth: 1.2)
                .scaleEffect(rippled ? 1.9 : 1.0)
            
            Circle()
                .fill(color)
                .scaleEffect(shown ? 1.0 : 0.2)
                .opacity(shown ? 1.0 : 0.0)
                .animation(.spring(response: 0.55, dampingFraction: 0.7), value: shown)
            
            CheckmarkShape()
                .trim(from: 0, to: shown ? 1.0 : 0.0)
                .stroke(Color.black.opacity(0.85), style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round, lineJoin: .round))
                .padding(size * 0.12)
                .animation(.easeInOut(duration: 0.5).delay(0.18), value: shown)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(shown ? 0.55 : 0.0), radius: 3)
        .animation(.easeOut(duration: 0.5), value: shown)
        .onAppear {
            shown = true
            withAnimation(.easeOut(duration: 0.9).delay(0.35)) { rippled = true }
        }
    }
}


/// A colour sweep that runs once around the notch's outline when it first appears.
private struct IntroGlowRing: View {
    let active: Bool
    let bottomRadius: CGFloat
    @State private var angle: Double = 0
    
    var body: some View {
        NotchShape(bottomRadius: bottomRadius)
            .stroke(
                AngularGradient(colors: [.cyan, .blue, .purple, .pink, .orange, .cyan], center: .center, angle: .degrees(angle)),
                lineWidth: 2.4
            )
            .blur(radius: 1.4)
            .shadow(color: Color.cyan.opacity(0.7), radius: 8)
            .opacity(active ? 1 : 0)
            .animation(.easeInOut(duration: 0.5), value: active)
            .onChange(of: active) { isActive in
                if isActive {
                    angle = 0
                    withAnimation(.linear(duration: 2.2)) { angle = 360 }
                }
            }
    }
}


/// Closing card: the contents dissolve into a blur instead of vanishing. One GPU blur for 0.3 s, nothing at rest.
struct CardBlurOut: ViewModifier {
    var amount: CGFloat
    // Only the fade is SwiftUI's; the blur is a Core Animation filter on the whole layer (NotchShellView), free per frame
    func body(content: Content) -> some View {
        content.opacity(1 - amount)
    }
}



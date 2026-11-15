import AppKit
import SwiftUI
import Combine

public final class NotchWindowController: ObservableObject {
    public static let shared = NotchWindowController()
    
    public let viewModel: NotchViewModel
    
    /// "All displays": one more notch on every other monitor, each with its own window and state
    private static var extraNotches: [NotchWindowController] = []
    private static var extraNotchesSync: AnyCancellable?
    
    public static func startExtraDisplays() {
        extraNotchesSync = Publishers.Merge(
            SettingsService.shared.$notchDisplayID.map { _ in () },
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).map { _ in () }
        )
        .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
        .sink { syncExtraDisplays() }
    }
    
    private static func syncExtraDisplays() {
        extraNotches.forEach { $0.hide() }
        extraNotches = []
        guard SettingsService.shared.notchDisplayID == "all" else { return }
        let primary = NotchManager.chosenScreen()
        extraNotches = NSScreen.screens.filter { $0 != primary }.map { NotchWindowController(viewModel: NotchViewModel(screen: $0)) }
    }
    private var panel: NotchPanel?
    private var cancellables = Set<AnyCancellable>()
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var hoverTimer: Timer?
    
    public init(viewModel: NotchViewModel = NotchViewModel()) {
        self.viewModel = viewModel
        setupPanel()
        bindViewModel()
        setupMouseTracking()
    }
    
    deinit {
        hoverTimer?.invalidate()
        if let g = globalMouseMonitor { NSEvent.removeMonitor(g) }
        if let l = localMouseMonitor { NSEvent.removeMonitor(l) }
    }
    
    private var isHoverTarget: Bool = false
    private var dragPasteboardCountAtMouseDown = NSPasteboard(name: .drag).changeCount
    
    /// A real drag of items (files, text): the drag pasteboard was refilled after the button went down. Moving a window
    /// leaves it untouched, and its stale contents from an earlier drag must not open the notch.
    private var isItemDragInProgress: Bool {
        let board = NSPasteboard(name: .drag)
        return NSEvent.pressedMouseButtons != 0 && board.changeCount != dragPasteboardCountAtMouseDown && !(board.types ?? []).isEmpty
    }
    
    private func setupMouseTracking() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown]
        let scrollMask: NSEvent.EventTypeMask = [.scrollWheel, .swipe, .otherMouseDown]
        
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: moveMask.union(scrollMask)) { [weak self] event in
            guard let self = self else { return }
            if event.type == .leftMouseDown { self.dragPasteboardCountAtMouseDown = NSPasteboard(name: .drag).changeCount }
            self.throttledHoverCheck()
            if event.type == .scrollWheel {
                self.viewModel.handleScrollWheel(event)
            } else if event.type == .swipe {
                self.viewModel.handleSwipe(event)
            } else if event.type == .otherMouseDown {
                self.viewModel.handleSideButton(event)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: moveMask.union(scrollMask)) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .leftMouseDown { self.dragPasteboardCountAtMouseDown = NSPasteboard(name: .drag).changeCount }
            self.throttledHoverCheck()
            if event.type == .scrollWheel {
                if self.viewModel.handleScrollWheel(event) {
                    return nil
                }
            } else if event.type == .swipe {
                if self.viewModel.handleSwipe(event) {
                    return nil
                }
            } else if event.type == .otherMouseDown {
                if self.viewModel.handleSideButton(event) { return nil }
            }
            return event
        }
    }
    
    private var lastHoverCheck: CFTimeInterval = 0
    private var trailingHoverCheck = false
    
    /// Mouse events arrive at the mouse's rate (up to 1000 Hz): the hover logic needs ~60 Hz, with one trailing check so a
    /// cursor that stops on the notch's edge is still seen.
    private func throttledHoverCheck() {
        let now = CACurrentMediaTime()
        if now - lastHoverCheck >= 1.0 / 60.0 {
            lastHoverCheck = now
            checkMouseHover()
        } else if !trailingHoverCheck {
            trailingHoverCheck = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self = self else { return }
                self.trailingHoverCheck = false
                self.lastHoverCheck = CACurrentMediaTime()
                self.checkMouseHover()
            }
        }
    }
    
    private func updateHoverTimerState() {
        if isHoverTarget {
            if hoverTimer == nil {
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                    self?.checkMouseHover()
                }
            }
        } else {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }
    
    /// Keeps the notch out of sight (first launch, while the welcome window is open).
    public func holdForIntro() {
        viewModel.isIntroHidden = true
    }
    
    /// The notch drops in from the top with an overshoot, stretches once, and a colour sweep runs around it.
    public func playIntro() {
        guard viewModel.isIntroHidden else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            self.panel?.orderFrontRegardless()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.55)) { self.viewModel.isIntroHidden = false }
            self.viewModel.introGlow = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.viewModel.triggerTemporaryWingExpansion(duration: 1.3, mode: .idle)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { self.viewModel.introGlow = false }
        }
    }
    
    private func checkMouseHover() {
        if viewModel.isIntroHidden { return }
        let mouseLoc = NSEvent.mouseLocation
        let screenMaxY = viewModel.notchInfo.screenFrame.maxY
        
        // Fast rejection: cursor is well below the notch window area and notch is not open
        // A cursor flung against the top edge sits at y == maxY, which CGRect.contains leaves out: test the x range alone
        let frame = viewModel.notchInfo.screenFrame
        if !isHoverTarget && (mouseLoc.y < (screenMaxY - viewModel.windowHeight) || mouseLoc.y > screenMaxY + 1 || mouseLoc.x < frame.minX || mouseLoc.x >= frame.maxX) {
            return
        }
        
        // Multi-monitor tracking: if mouse is on a different screen, update NotchManager
        NotchManager.shared.updateScreenForMouseLocation(mouseLoc)
        
        var targetRect: CGRect
        if isHoverTarget {
            // While open, maintain expansion with a small border around the card
            targetRect = viewModel.currentPillRectOnScreen.insetBy(dx: -6, dy: -6)
        } else {
            // When hidden on external displays, use a comfortable trigger zone at top center
            let triggerPadding: CGFloat = viewModel.isNotchHiddenInIdleOnExternal ? 15.0 : 0.0
            targetRect = viewModel.notchInfo.notchRect.insetBy(dx: -triggerPadding, dy: -1)
            // Pushed against the very top: a little wider, a flick rarely lands exactly within the notch's width
            if mouseLoc.y >= screenMaxY - 2 { targetRect = targetRect.insetBy(dx: -24, dy: 0) }
            // Dragging something: open from a much larger zone around the notch, so there's no need to aim at the pill
            let dragZone = viewModel.notchInfo.notchRect.insetBy(dx: -90, dy: -55)
            // The drag pasteboard is an IPC call: only look at it while a button is down and the cursor is near
            if NSEvent.pressedMouseButtons != 0, dragZone.contains(mouseLoc), isItemDragInProgress {
                targetRect = dragZone
            }
        }
        
        // A button held down while crossing the notch (dragging a window, selecting) must not open it; a file drag may
        let pressedElsewhere = !isHoverTarget && NSEvent.pressedMouseButtons != 0 && !isItemDragInProgress
        let isInside = targetRect.contains(mouseLoc) && !pressedElsewhere
        // The blocks only make sense during the drag: drop (or leaving) ends it
        if !viewModel.draggedFiles.isEmpty && NSEvent.pressedMouseButtons == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                if NSEvent.pressedMouseButtons == 0 {
                    withAnimation(NotchViewModel.springAnimation) { self?.viewModel.draggedFiles = [] }
                }
            }
        }
        if isHoverTarget != isInside {
            isHoverTarget = isInside
            updateHoverTimerState()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Opens with a slight overshoot, closes without bouncing
                withAnimation(isInside ? NotchViewModel.springAnimation : NotchViewModel.closeAnimation) {
                    // Something is being dragged to the notch: open straight on the clipboard, where it will be saved
                    if isInside, self.isItemDragInProgress {
                        if self.viewModel.visibleTabs.contains(.clipboard) { self.viewModel.selectedTab = .clipboard }
                        self.viewModel.draggedFiles = FileConverter.urlsBeingDragged()
                    }
                    self.viewModel.isHovered = isInside
                }
                // The format ring follows the card's own animation; it is dropped once the card has finished closing
                if !isInside {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        if self?.isHoverTarget == false { self?.viewModel.draggedFiles = [] }
                    }
                }
            }
        }
    }
    
    private func setupPanel() {
        let frame = viewModel.windowFrame
        let panel = NotchPanel(contentRect: frame)
        panel.viewModel = viewModel
        
        let contentView = NotchyView(viewModel: viewModel)
        let hostingView = NotchHostingView(rootView: contentView, viewModel: viewModel)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        
        panel.contentView = NotchShellView(frame: hostingView.frame, content: hostingView, viewModel: viewModel)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        
        self.panel = panel
    }
    
    private func bindViewModel() {
        viewModel.$notchInfo
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateFrame()
            }
            .store(in: &cancellables)
            
        viewModel.$isHovered
            .receive(on: RunLoop.main)
            .sink { [weak self] hovered in
                if hovered {
                    self?.panel?.orderFrontRegardless()
                }
            }
            .store(in: &cancellables)
            
        // Tell the recorder when the notch is expanded, so it hides it from recordings only then (see ScreenRecorderService)
        Publishers.MergeMany(
            viewModel.$isHovered.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isTemporaryWingExpanded.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isWaitingConfirmation.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isRecordingScreen.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            guard let self = self else { return }
            ScreenRecorderService.shared.setNotchExpanded(self.viewModel.isVisuallyExpanded)
        }
        .store(in: &cancellables)
            
        viewModel.$isTemporaryWingExpanded
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                if expanded {
                    self?.panel?.orderFrontRegardless()
                }
            }
            .store(in: &cancellables)
            
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.panel?.orderFrontRegardless()
            }
            .store(in: &cancellables)
            
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.panel?.orderFrontRegardless()
            }
            .store(in: &cancellables)
    }
    
    public func show() {
        guard let panel = panel else { return }
        updateFrame()
        panel.orderFrontRegardless()
    }
    
    public func hide() {
        panel?.orderOut(nil)
    }
    
    public func updateFrame() {
        guard let panel = panel else { return }
        let targetFrame = viewModel.windowFrame
        panel.setFrame(targetFrame, display: true)
    }
}

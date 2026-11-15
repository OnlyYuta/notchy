import Combine
import AppKit
import SwiftUI

public final class NotchHostingView<Content: View>: NSHostingView<Content> {
    private weak var viewModel: NotchViewModel?
    
    public init(rootView: Content, viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(rootView: rootView)
    }
    
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @MainActor required init(rootView: Content) {
        super.init(rootView: rootView)
    }
    
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let viewModel = viewModel else {
            return super.hitTest(point)
        }
        // If completely disabled or hidden in idle on external display, pass all events through
        if viewModel.isNotchCompletelyDisabled || (viewModel.isNotchHiddenInIdleOnExternal && !viewModel.isHovered) {
            return nil
        }
        // Only accept hits if the cursor is within the current visible notch pill.
        // Anywhere outside returns nil, passing events to menu bar and background windows.
        if viewModel.activePillRectInWindow.contains(point) {
            return super.hitTest(point)
        }
        return nil
    }
    
    public override func scrollWheel(with event: NSEvent) {
        if viewModel?.handleScrollWheel(event) == true {
            return
        }
        super.scrollWheel(with: event)
    }
    
    public override func swipe(with event: NSEvent) {
        if viewModel?.handleSwipe(event) == true {
            return
        }
        super.swipe(with: event)
    }
}

public final class NotchPanel: NSPanel {
    public weak var viewModel: NotchViewModel?
    
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        self.isFloatingPanel = true
        // Position above all applications and full-screen spaces, below popups
        // Above menus and every app window: nothing may draw over the notch, as with the real one
        self.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.colorSpace = .sRGB
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = true
        self.isReleasedWhenClosed = false
    }
    
    public override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel {
            if viewModel?.handleScrollWheel(event) == true {
                return
            }
        } else if event.type == .swipe {
            if viewModel?.handleSwipe(event) == true {
                return
            }
        }
        super.sendEvent(event)
    }
    
    public override var canBecomeKey: Bool {
        return false
    }
    
    public override var canBecomeMain: Bool {
        return false
    }
}

/// The notch itself: its black silhouette, shadow and outline, and the mask that cuts the SwiftUI content to it, all
/// as Core Animation layers. Their springs run in the render server at the display's full refresh rate, so opening and
/// closing cost the app nothing per frame (a SwiftUI frame/clip animation re-laid out the whole tree on every frame).
public final class NotchShellView: NSView {
    private weak var viewModel: NotchViewModel?
    private let fillLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private let maskLayer = CAShapeLayer()
    private let content: NSView
    /// Holds the notch-shaped mask, so the content inside can be scaled without scaling its own clip
    private let clip = PassthroughView()
    private var sync: AnyCancellable?
    private var last: (w: CGFloat, h: CGFloat, r: CGFloat, hidden: Bool, ring: Bool)?
    private var lastExpanded: Bool?
    
    public init(frame: NSRect, content: NSView, viewModel: NotchViewModel) {
        self.content = content
        self.viewModel = viewModel
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        
        fillLayer.fillColor = NSColor.black.cgColor
        fillLayer.shadowColor = NSColor.black.cgColor
        fillLayer.shadowRadius = 16
        fillLayer.shadowOffset = CGSize(width: 0, height: -8)
        fillLayer.shadowOpacity = 0
        strokeLayer.fillColor = nil
        strokeLayer.strokeColor = NSColor.white.withAlphaComponent(0.09).cgColor
        strokeLayer.lineWidth = 0.6
        strokeLayer.opacity = 0
        layer?.addSublayer(fillLayer)
        
        clip.frame = bounds
        clip.autoresizingMask = [.width, .height]
        clip.wantsLayer = true
        addSubview(clip)
        clip.layer?.mask = maskLayer
        content.frame = clip.bounds
        content.autoresizingMask = [.width, .height]
        clip.addSubview(content)
        content.wantsLayer = true
        content.layerUsesCoreImageFilters = true
        // The outline sits above the content, as the SwiftUI overlay did
        layer?.addSublayer(strokeLayer)
        
        apply(animated: false)
        // objectWillChange fires before the change: read the new state on the next pass
        sync = viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.apply(animated: true) }
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    /// Clicks outside the SwiftUI content must fall through to the windows below
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    
    public override func layout() {
        super.layout()
        for l in [fillLayer, strokeLayer, maskLayer] { l.frame = bounds }
    }
    
    /// NotchShape is drawn top-down; the layers here (this view's and the clip's) are bottom-up
    private func path(width w: CGFloat, height h: CGFloat, radius r: CGFloat) -> CGPath {
        let rect = CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: h)
        let shape = NotchShape(bottomRadius: r).path(in: rect).cgPath
        var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        return shape.copy(using: &flip) ?? shape
    }
    
    /// The card comes into focus as it opens and blurs away as it closes. The filter lives only for the transition:
    /// a resting blur filter would render the layer offscreen all the time.
    private func blurTransition(opening: Bool) {
        guard let layer = content.layer, let blur = CIFilter(name: "CIGaussianBlur") else { return }
        blur.name = "cardBlur"
        let (from, to, duration): (CGFloat, CGFloat, Double) = opening ? (8, 0, 0.3) : (0, 9, 0.25)
        blur.setValue(to, forKey: kCIInputRadiusKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak layer] in
            // a newer transition has replaced the filter: leave it alone
            if layer?.animation(forKey: "cardBlur") == nil, self?.lastExpanded == opening { layer?.filters = nil }
        }
        layer.filters = [blur]
        let a = CABasicAnimation(keyPath: "filters.cardBlur.inputRadius")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: opening ? .easeOut : .easeIn)
        layer.add(a, forKey: "cardBlur")
        CATransaction.commit()
    }
    
    /// The content grows with the notch from its top centre on the notch's own spring (and shrinks a little as it
    /// closes), instead of sitting full-size behind a widening mask. An additive-free animation of the layer's
    /// transform only: the model stays identity, so AppKit's own layout of the view is untouched.
    private func growTransition(opening: Bool, from oldWidth: CGFloat, to newWidth: CGFloat, spring: (response: Double, damping: Double)) {
        guard let layer = content.layer, newWidth > 0 else { return }
        // Same spring and same start/end as the silhouette's width: the content's width is the notch's in every frame
        let s = opening ? max(0.05, min(1, oldWidth / newWidth)) : 0.9
        // A transform acts around the layer's anchorPoint, in its parent's orientation: this (unflipped) view is
        // bottom-up, so the notch's top edge is at maxY whatever the SwiftUI layer's own flipping
        let pivot = CGPoint(x: layer.bounds.width * (0.5 - layer.anchorPoint.x),
                            y: layer.bounds.height * (1 - layer.anchorPoint.y))
        var t = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -pivot.x, -pivot.y, 0)
        let a: CABasicAnimation
        if opening {
            let sp = CASpringAnimation(keyPath: "transform")
            sp.mass = 1
            sp.stiffness = pow(2 * .pi / spring.response, 2)
            sp.damping = 4 * .pi * spring.damping / spring.response
            sp.duration = sp.settlingDuration
            sp.fromValue = t
            sp.toValue = CATransform3DIdentity
            a = sp
        } else {
            // only as long as the card's fade: when it ends the card is gone and the transform snaps back unseen
            a = CABasicAnimation(keyPath: "transform")
            a.fromValue = CATransform3DIdentity
            a.toValue = t
            a.duration = 0.25
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        layer.add(a, forKey: "grow")
    }
    
    private func apply(animated: Bool) {
        guard let vm = viewModel else { return }
        let hidden = vm.isIntroHidden || vm.isNotchCompletelyDisabled || (vm.isNotchHiddenInIdleOnExternal && !vm.isHovered)
        var w = vm.currentWidth, h = vm.currentHeight
        if hidden { w *= 0.3; h = 0 }
        let r = vm.currentCornerRadius
        // the format ring around the notch lives outside its silhouette: the mask then also opens everything around the card
        let ring = vm.isFormatRingPresent
        if let l = last, l.w == w, l.h == h, l.r == r, l.hidden == hidden, l.ring == ring { return }
        
        // Opening overshoots slightly, closing settles without a bounce, the first appearance springs in
        let previousWidth = last?.w ?? w
        let spring: (response: Double, damping: Double)
        // the bouncy drop-in is for the first appearance only; a notch hidden on an external display reveals with the normal open spring
        if let l = last, l.hidden && !hidden && !vm.isHovered { spring = (0.7, 0.55) }
        else if let l = last, h < l.h { spring = (0.34, 0.94) }
        else { spring = (0.42, 0.78) }
        last = (w, h, r, hidden, ring)
        
        let target = path(width: w, height: h, radius: r)
        let expanded = vm.isHovered
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, key) in [(fillLayer, "path"), (strokeLayer, "path"), (maskLayer, "path"), (fillLayer, "shadowPath")] {
            let from: CGPath? = key == "path" ? (layer.presentation()?.path ?? layer.path) : (layer.presentation()?.shadowPath ?? layer.shadowPath)
            var to = target
            if layer === maskLayer, ring {
                // even-odd: the whole view, minus the open card's box, plus the (animating) notch inside it. The box is the
                // final one, so the card's content never shows outside the silhouette while it grows.
                let open = CGMutablePath()
                let ow = NotchViewModel.openWidth, oh = vm.expandedHeight
                open.addRect(bounds)
                open.addRect(CGRect(x: (bounds.width - ow) / 2, y: bounds.height - oh, width: ow, height: oh))
                open.addPath(target)
                to = open
            }
            if layer === maskLayer { maskLayer.fillRule = ring ? .evenOdd : .nonZero }
            if key == "path" { layer.path = to } else { layer.shadowPath = to }
            guard animated, let from = from else { continue }
            let a = CASpringAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.mass = 1
            a.stiffness = pow(2 * .pi / spring.response, 2)
            a.damping = 4 * .pi * spring.damping / spring.response
            a.duration = a.settlingDuration
            layer.add(a, forKey: key)
        }
        CATransaction.commit()
        
        // Shadow and outline belong to the open card; they follow it in and out
        if expanded != lastExpanded {
            // a file drag opens with the format ring: the full-size blur under it is what drops frames there
            if animated && lastExpanded != nil && !ring {
                blurTransition(opening: expanded)
                growTransition(opening: expanded, from: previousWidth, to: w, spring: spring)
            }
            lastExpanded = expanded
            CATransaction.begin()
            CATransaction.setAnimationDuration(expanded ? 0.3 : 0.2)
            fillLayer.shadowOpacity = expanded ? 0.5 : 0
            strokeLayer.opacity = expanded ? 1 : 0
            CATransaction.commit()
        }
    }
}

/// A plain container that is never itself the target of a click: those fall through to what is below
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

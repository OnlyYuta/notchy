import SwiftUI
import AppKit

// MARK: - Official Claude Logo (Anthropic Asterisk)
public struct ClaudeIconShape: View {
    public static let logoImage: NSImage? = {
        let names = ["ClaudeLogo", "claude_logo"]
        for name in names {
            if let path = Bundle.main.path(forResource: name, ofType: "png"),
               let img = NSImage(contentsOfFile: path) { return img }
            let bundleRes = Bundle.main.bundlePath + "/Contents/Resources/\(name).png"
            if let img = NSImage(contentsOfFile: bundleRes) { return img }
        }
        return nil
    }()
    
    public init() {}
    
    public var body: some View {
        if let img = Self.logoImage {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "asterisk")
                .resizable()
                .scaledToFit()
                .foregroundColor(Color(red: 0.90, green: 0.48, blue: 0.35))
        }
    }
}

// MARK: - Official Codex Logo (Terminal Cloud)
public struct CodexIconShape: View {
    public static let logoImage: NSImage? = {
        let names = ["CodexLogo", "codex_logo"]
        for name in names {
            if let path = Bundle.main.path(forResource: name, ofType: "png"),
               let img = NSImage(contentsOfFile: path) { return img }
            let bundleRes = Bundle.main.bundlePath + "/Contents/Resources/\(name).png"
            if let img = NSImage(contentsOfFile: bundleRes) { return img }
        }
        return nil
    }()
    
    public init() {}
    
    public var body: some View {
        if let img = Self.logoImage {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "terminal.fill")
                .resizable()
                .scaledToFit()
                .foregroundColor(Color(red: 0.10, green: 0.88, blue: 0.55))
        }
    }
}

// MARK: - Official Antigravity Logo (Multicolor Arch)
public struct AntigravityIconShape: View {
    public static let logoImage: NSImage? = {
        // 1. Try bundle resources
        if let path = Bundle.main.path(forResource: "AntigravityLogo", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            return img
        }
        // 2. Try app bundle Contents/Resources
        let bundleRes = Bundle.main.bundlePath + "/Contents/Resources/AntigravityLogo.png"
        if let img = NSImage(contentsOfFile: bundleRes) {
            return img
        }
        return nil
    }()
    
    public init() {}
    
    public var body: some View {
        if let img = Self.logoImage {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
        } else {
            // Fallback icon if file not found
            Image(systemName: "sparkles")
                .resizable()
                .scaledToFit()
                .foregroundColor(Color(red: 0.2, green: 0.5, blue: 1.0))
        }
    }
}

// MARK: - Unified Agent Badge View with Breathing Glow
public struct AgentBadgeView: View {
    public let agent: AgentType
    public var size: CGFloat = 16.0
    public var isBreathing: Bool = true
    /// Slow glow pulse, used while the agent is working
    public var isPulsing: Bool = false
    
    public init(agent: AgentType, size: CGFloat = 16.0, isBreathing: Bool = true, isPulsing: Bool = false) {
        self.agent = agent
        self.size = size
        self.isBreathing = isBreathing
        self.isPulsing = isPulsing
    }
    
    public var body: some View {
        let glowColor: Color = {
            switch agent {
            case .antigravity:
                return Color.blue
            case .claude:
                return Color(red: 0.90, green: 0.48, blue: 0.35)
            case .codex:
                return Color(red: 0.10, green: 0.88, blue: 0.55)
            case .cursor, .gemini, .copilot:
                return agent.accentColor
            }
        }()
        
        ZStack {
            if isBreathing {
                if isPulsing {
                    CAGlowPulse(color: NSColor(glowColor))
                        .frame(width: size * 1.5, height: size * 1.5)
                } else {
                    glow(glowColor, opacity: 0.35, scale: 1.45)
                }
            }
            
            Group {
                switch agent {
                case .claude:
                    ClaudeIconShape()
                case .codex:
                    CodexIconShape()
                case .antigravity:
                    AntigravityIconShape()
                case .cursor:
                    Image(systemName: "cursorarrow.rays").resizable().scaledToFit().foregroundColor(agent.accentColor)
                case .gemini:
                    Image(systemName: "sparkle").resizable().scaledToFit().foregroundColor(agent.accentColor)
                case .copilot:
                    Image(systemName: "airplane").resizable().scaledToFit().foregroundColor(agent.accentColor)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: glowColor.opacity(isBreathing ? 0.65 : 0.25), radius: 2.5)
        }
        .frame(width: size * 1.5, height: size * 1.5)
    }
    
    private func glow(_ color: Color, opacity: Double, scale: CGFloat) -> some View {
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: size * scale, height: size * scale)
            .blur(radius: 2.5)
    }
}

// MARK: - Animated Three Dots (Thinking / Working Indicator)
public struct ThreeDotsView: View {
    public init() {}
    
    public var body: some View {
        CAThreeDots()
            .frame(width: CAThreeDots.width, height: CAThreeDots.height)
        .frame(height: 12, alignment: .center)
        .padding(.horizontal, 2)
    }
}

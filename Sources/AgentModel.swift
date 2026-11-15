import SwiftUI

public enum WorkState: String, Codable {
    case idle
    case promptReceived
    case working
    case done
    case needsConfirmation
}

/// Единое место для путей приложения (вместо разрозненных файлов в /tmp).
public enum AppPaths {
    public static let supportDir: URL = {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let url = support.appendingPathComponent("Notchy", isDirectory: true)
        // The app used to be called DynamicNotch: carry its data (clipboard history, hook script) over once
        let old = support.appendingPathComponent("DynamicNotch", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.moveItem(at: old, to: url)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    /// Каталог для внешних управляющих файлов (скрипты из scripts/).
    public static let ipcDir: URL = {
        let url = supportDir.appendingPathComponent("ipc", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    public static let cacheDir: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchy", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

public enum AgentType: String, CaseIterable, Identifiable, Codable {
    case claude = "claude"
    case codex = "codex"
    case antigravity = "antigravity"
    case cursor = "cursor"
    case gemini = "gemini"
    case copilot = "copilot"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini"
        case .copilot: return "Copilot"
        }
    }
    
    /// Имя агента из хука (поле lumio_agent) -> тип. Неизвестное значение — nil.
    public init?(hookName: String) {
        self.init(rawValue: hookName.lowercased())
    }
    
    /// Принадлежит ли запущенное приложение этому агенту (для перехода по клику).
    public func matches(bundleId: String?, name: String?) -> Bool {
        let bid = (bundleId ?? "").lowercased()
        let n = (name ?? "").lowercased()
        switch self {
        case .antigravity: return bid.contains("antigravity") || n.contains("antigravity")
        case .claude: return bid.hasPrefix("com.anthropic.claude") || n == "claude"
        case .codex: return bid.contains("codex") || n.contains("codex")
        case .cursor: return bid.hasPrefix("com.todesktop.230313mzl4w4u92") || n == "cursor"
        case .gemini: return bid.contains("gemini") || n.contains("gemini")
        case .copilot: return bid.contains("copilot") || n.contains("copilot")
        }
    }
    
    public var accentColor: Color {
        switch self {
        case .claude:
            return Color(red: 0.90, green: 0.48, blue: 0.35)
        case .codex:
            return Color(red: 0.06, green: 0.76, blue: 0.52)
        case .antigravity:
            return Color(red: 0.20, green: 0.50, blue: 1.0)
        case .cursor:
            return Color(red: 0.85, green: 0.85, blue: 0.90)
        case .gemini:
            return Color(red: 0.35, green: 0.55, blue: 1.0)
        case .copilot:
            return Color(red: 0.55, green: 0.40, blue: 0.95)
        }
    }
}

public struct AgentInstance: Identifiable, Equatable, Codable {
    public var id: String
    public var agent: AgentType
    public var projectName: String
    public var workState: WorkState
    public var statusDescription: String?
    public var hasBeenSeen: Bool
    public var completedAt: Date?
    public var subagentCount: Int
    
    public init(
        id: String = UUID().uuidString,
        agent: AgentType,
        projectName: String = "",
        workState: WorkState = .working,
        statusDescription: String? = nil,
        hasBeenSeen: Bool = false,
        completedAt: Date? = nil,
        subagentCount: Int = 0
    ) {
        self.id = id
        self.agent = agent
        self.projectName = projectName
        self.workState = workState
        self.statusDescription = statusDescription
        self.hasBeenSeen = hasBeenSeen
        self.completedAt = completedAt
        self.subagentCount = subagentCount
    }
}

import Foundation
import AppKit

/// Устанавливает hook-скрипт и регистрирует его в конфигах агентов (Claude Code, Codex, Cursor, Antigravity).
/// Чужие хуки не трогаем: добавляем только свою запись и перед первым изменением делаем резервную копию.
public enum HookAgent: String, CaseIterable, Identifiable {
    case claude, codex, antigravity, cursor
    public var id: String { rawValue }
    public var agentType: AgentType { AgentType(rawValue: rawValue) ?? .claude }
}

public final class AgentHookManager {
    public static let shared = AgentHookManager()

    private let fileManager = FileManager.default
    private let marker = "notchy-hook.pl"
    /// Entries written under the old app name (DynamicNotch) count as ours: they are replaced, not left dangling.
    private let legacyMarker = "dynamicnotch-hook.pl"
    private func isOurs(_ command: String?) -> Bool {
        guard let c = command else { return false }
        return c.contains(marker) || c.contains(legacyMarker)
    }

    public var notchySupportDir: URL { AppPaths.supportDir }

    public var hookScriptURL: URL {
        notchySupportDir.appendingPathComponent(marker)
    }

    private var home: URL { fileManager.homeDirectoryForCurrentUser }

    private init() {
        // Старый общий флаг отказа -> отдельные флаги по агентам
        if UserDefaults.standard.bool(forKey: "agentHooksDisabled") {
            for a in HookAgent.allCases { UserDefaults.standard.set(false, forKey: enabledKey(a)) }
            UserDefaults.standard.removeObject(forKey: "agentHooksDisabled")
        }
    }

    // MARK: - Public API

    private func enabledKey(_ a: HookAgent) -> String { "agentHook.\(a.rawValue)" }

    /// Подключён ли показ работы агента. Агенты без хуков (Gemini, Copilot) считаются включёнными.
    public func isEnabled(_ agent: AgentType) -> Bool {
        guard let a = HookAgent(rawValue: agent.rawValue) else { return true }
        return isEnabled(a)
    }

    public func isEnabled(_ a: HookAgent) -> Bool {
        UserDefaults.standard.object(forKey: enabledKey(a)) as? Bool ?? true
    }

    /// force — явный запрос пользователя (меню): включает всех; автозапуск уважает отказ по каждому агенту.
    public func installHooks(force: Bool = false) {
        if force { for a in HookAgent.allCases { UserDefaults.standard.set(true, forKey: enabledKey(a)) } }
        let targets = HookAgent.allCases.filter { isEnabled($0) }
        guard !targets.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            guard self.ensureHookScriptInstalled() else { return }
            targets.forEach(self.configure)
            self.notifyChanged()
        }
    }

    /// Убирает записи Notchy из конфигов всех агентов (резервные копии остаются).
    public func removeHooks() {
        for a in HookAgent.allCases { setEnabled(a, false) }
    }

    /// Включает или выключает показ работы одного агента: пишет/убирает его хук и сразу скрывает/показывает его в челке.
    public func setEnabled(_ a: HookAgent, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey(a))
        AgentStatusService.shared.refreshAgentFilter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            if on {
                guard self.ensureHookScriptInstalled() else { return }
                self.configure(a)
            } else {
                self.strip(a)
            }
            self.notifyChanged()
        }
    }

    /// Установлен ли сам агент (есть его каталог конфигов или приложение).
    public func isAgentPresent(_ a: HookAgent) -> Bool {
        switch a {
        case .claude:
            return fileManager.fileExists(atPath: home.appendingPathComponent(".claude").path)
                || fileManager.fileExists(atPath: "/Applications/Claude.app")
                || ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home.appendingPathComponent(".local/bin/claude").path]
                    .contains { fileManager.fileExists(atPath: $0) }
        case .codex:
            return fileManager.fileExists(atPath: home.appendingPathComponent(".codex").path) || fileManager.fileExists(atPath: "/Applications/Codex.app")
        case .cursor:
            return fileManager.fileExists(atPath: home.appendingPathComponent(".cursor").path) || fileManager.fileExists(atPath: "/Applications/Cursor.app")
        case .antigravity:
            return fileManager.fileExists(atPath: home.appendingPathComponent(".gemini").path) || fileManager.fileExists(atPath: "/Applications/Antigravity.app")
        }
    }

    /// Есть ли в конфиге агента запись Notchy.
    public func isHookInstalled(_ a: HookAgent) -> Bool {
        guard let data = try? Data(contentsOf: configURL(a)) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        return text.contains(marker) || text.contains(legacyMarker)
    }

    private func configURL(_ a: HookAgent) -> URL {
        switch a {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        case .cursor: return home.appendingPathComponent(".cursor/hooks.json")
        case .antigravity: return home.appendingPathComponent(".gemini/config/hooks.json")
        }
    }

    private func configure(_ a: HookAgent) {
        switch a {
        case .claude: configureClaudeCodeHooks()
        case .codex: configureCodexHooks()
        case .cursor: configureCursorHooks()
        case .antigravity: configureAntigravityHooks()
        }
    }

    private func strip(_ a: HookAgent) {
        let url = configURL(a)
        if a == .antigravity {
            if var root = readJSON(url), root.removeValue(forKey: "notchy") != nil { writeJSON(root, to: url) }
        } else {
            stripHooks(at: url)
        }
    }

    private func notifyChanged() {
        DispatchQueue.main.async { AgentConnections.shared.refresh() }
    }

    // MARK: - Hook Script Deployment

    @discardableResult
    private func ensureHookScriptInstalled() -> Bool {
        guard let bundled = Bundle.main.url(forResource: "notchy-hook", withExtension: "pl"),
              let srcData = try? Data(contentsOf: bundled) else {
            NSLog("[AgentHookManager] Bundled hook script not found")
            return fileManager.fileExists(atPath: hookScriptURL.path)
        }
        do {
            try fileManager.createDirectory(at: notchySupportDir, withIntermediateDirectories: true)
            if (try? Data(contentsOf: hookScriptURL)) != srcData {
                try srcData.write(to: hookScriptURL, options: .atomic)
            }
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptURL.path)
            return true
        } catch {
            NSLog("[AgentHookManager] Error preparing hook script: \(error)")
            return false
        }
    }

    // MARK: - JSON helpers

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    /// Файл существует, но не разбирается как JSON — его лучше не трогать.
    private func isUnreadableExisting(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) && readJSON(url) == nil
            && ((try? Data(contentsOf: url))?.isEmpty == false)
    }

    private func writeJSON(_ object: [String: Any], to url: URL) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[AgentHookManager] Error writing \(url.path): \(error)")
        }
    }

    private func backupOnce(_ url: URL) {
        let backup = url.appendingPathExtension("notchy-backup")
        guard fileManager.fileExists(atPath: url.path), !fileManager.fileExists(atPath: backup.path) else { return }
        try? fileManager.copyItem(at: url, to: backup)
    }

    private func entryHasMarker(_ entry: [String: Any]) -> Bool {
        if let inner = entry["hooks"] as? [[String: Any]] {
            return inner.contains { isOurs($0["command"] as? String) }
        }
        return isOurs(entry["command"] as? String)
    }

    private func stripHooks(at url: URL) {
        guard var root = readJSON(url) else { return }
        var container = (root["hooks"] as? [String: Any]) ?? root
        let nested = root["hooks"] != nil
        for (event, value) in container {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !entryHasMarker($0) }
            if kept.isEmpty { container.removeValue(forKey: event) } else { container[event] = kept }
        }
        if nested { root["hooks"] = container } else { root = container }
        writeJSON(root, to: url)
    }

    /// Добавляет команду хука к каждому событию (формат Claude Code / Codex: hooks → [{hooks:[{command}]}]).
    /// Возвращает false, если конфиг нельзя безопасно изменить.
    @discardableResult
    private func registerNestedHooks(file: URL, events: [String], command: String, timeout: Int = 5) -> Bool {
        if isUnreadableExisting(file) {
            NSLog("[AgentHookManager] Skipping \(file.path): not valid JSON")
            return false
        }
        var settings = readJSON(file) ?? [:]
        var hooksDict = (settings["hooks"] as? [String: Any]) ?? [:]
        var changed = false

        for event in events {
            var entries = (hooksDict[event] as? [[String: Any]]) ?? []
            if let idx = entries.firstIndex(where: entryHasMarker) {
                // Уже есть — обновляем команду, если изменился путь
                if var inner = entries[idx]["hooks"] as? [[String: Any]],
                   let hi = inner.firstIndex(where: { isOurs($0["command"] as? String) }),
                   (inner[hi]["command"] as? String) != command {
                    inner[hi]["command"] = command
                    entries[idx]["hooks"] = inner
                    changed = true
                }
            } else {
                entries.append(["hooks": [["type": "command", "command": command, "timeout": timeout]]])
                changed = true
            }
            hooksDict[event] = entries
        }

        guard changed else { return true }
        backupOnce(file)
        try? fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        settings["hooks"] = hooksDict
        writeJSON(settings, to: file)
        NSLog("[AgentHookManager] Registered hooks in \(file.path)")
        return true
    }

    // MARK: - Claude Code

    private func configureClaudeCodeHooks() {
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        let installed = fileManager.fileExists(atPath: claudeDir.path)
            || fileManager.fileExists(atPath: "/Applications/Claude.app")
            || ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home.appendingPathComponent(".local/bin/claude").path]
                .contains { fileManager.fileExists(atPath: $0) }
        guard installed else { return }

        registerNestedHooks(
            file: claudeDir.appendingPathComponent("settings.json"),
            events: ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification",
                     "PermissionRequest", "SubagentStart", "SubagentStop", "SessionEnd"],
            command: "\"\(hookScriptURL.path)\" claude"
        )
    }

    // MARK: - Codex

    private func configureCodexHooks() {
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        guard fileManager.fileExists(atPath: codexDir.path) || fileManager.fileExists(atPath: "/Applications/Codex.app") else { return }

        registerNestedHooks(
            file: codexDir.appendingPathComponent("hooks.json"),
            events: ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                     "SubagentStart", "SubagentStop", "Stop", "SessionEnd"],
            command: "\"\(hookScriptURL.path)\" codex",
            timeout: 5
        )
    }

    // MARK: - Cursor

    private func configureCursorHooks() {
        let cursorDir = home.appendingPathComponent(".cursor", isDirectory: true)
        guard fileManager.fileExists(atPath: cursorDir.path) || fileManager.fileExists(atPath: "/Applications/Cursor.app") else { return }
        let hooksFile = cursorDir.appendingPathComponent("hooks.json")
        if isUnreadableExisting(hooksFile) { return }

        var root = readJSON(hooksFile) ?? [:]
        if root["version"] == nil { root["version"] = 1 }
        // Прежние версии писали события в корень файла — убираем свои записи оттуда
        for (key, value) in root where key != "version" && key != "hooks" {
            if let entries = value as? [[String: Any]], entries.contains(where: entryHasMarker) {
                let kept = entries.filter { !entryHasMarker($0) }
                if kept.isEmpty { root.removeValue(forKey: key) } else { root[key] = kept }
            }
        }
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var changed = false
        let command = "\"\(hookScriptURL.path)\" cursor"

        for event in ["sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure",
                      "subagentStart", "subagentStop", "afterAgentResponse", "stop", "sessionEnd"] {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            if let idx = entries.firstIndex(where: { isOurs($0["command"] as? String) }) {
                if (entries[idx]["command"] as? String) != command {
                    entries[idx]["command"] = command
                    changed = true
                }
            } else {
                entries.append(["command": command])
                changed = true
            }
            hooks[event] = entries
        }
        guard changed else { return }
        backupOnce(hooksFile)
        root["hooks"] = hooks
        writeJSON(root, to: hooksFile)
    }

    // MARK: - Antigravity

    private func configureAntigravityHooks() {
        let geminiDir = home.appendingPathComponent(".gemini", isDirectory: true)
        guard fileManager.fileExists(atPath: geminiDir.path) || fileManager.fileExists(atPath: "/Applications/Antigravity.app") else { return }

        let hooksFile = geminiDir.appendingPathComponent("config/hooks.json")
        if isUnreadableExisting(hooksFile) { return }
        try? fileManager.createDirectory(at: hooksFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        let script = hookScriptURL.path
        func flat(_ event: String, timeout: Int = 5) -> [[String: Any]] {
            [["command": "\"\(script)\" antigravity \(event)", "timeout": timeout, "type": "command"]]
        }
        func matched(_ event: String, timeout: Int = 5) -> [[String: Any]] {
            [["hooks": [["command": "\"\(script)\" antigravity \(event)", "timeout": timeout, "type": "command"]], "matcher": ".*"]]
        }
        let config: [String: Any] = [
            "PreInvocation": flat("PreInvocation"),
            "PreToolUse": matched("PreToolUse", timeout: 135),
            "PostToolUse": matched("PostToolUse"),
            "Stop": flat("Stop")
        ]

        var root = readJSON(hooksFile) ?? [:]
        if let existing = root["notchy"] as? [String: Any],
           NSDictionary(dictionary: existing).isEqual(to: config) { return }
        backupOnce(hooksFile)
        root["notchy"] = config
        writeJSON(root, to: hooksFile)
    }
}

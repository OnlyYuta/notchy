import Foundation
import SwiftUI

// MARK: - Raw Hook Event Model

private struct RawHookEvent: Decodable {
    let session_id: String?
    let lumio_agent: String?
    let cwd: String?
    let hook_event_name: String?
    let tool_name: String?
    let notification_type: String?
    let lumio_question: String?
    let message: String?
    let prompt: String?
    let agent_id: String?
    let transcript_path: String?
    let ts: Double?
}

// MARK: - Internal Session Tracker

private struct HookSessionTracker {
    var id: String
    var agent: AgentType
    var projectName: String
    /// Project root: the hook's cwd follows `cd`, the card must not (it would split into "notch" and "Sources")
    var rootCwd: String = ""
    var transcriptPath: String?
    /// Stop пришёл, пока работали субагенты: «готово» выставим, когда они затихнут
    var deferredStop: Date?
    var workState: WorkState
    var statusDescription: String?
    var lastUpdate: Date
    var completedAt: Date?
    var hasBeenSeen: Bool = false
    var subagentCount: Int = 0
    /// Субагенты по agent_id с временем последнего события: SubagentStart приходит редко, а события работы субагента
    /// всегда несут его agent_id, так что считаем тех, кто подавал признаки жизни недавно.
    var subagentSeen: [String: Date] = [:]
    var activeSubagents: Int { max(subagentCount, subagentSeen.count) }
}

/// Читает события хуков (agent-events.jsonl) и превращает их в список работающих агентов.
/// Новые строки подхватываются через DispatchSource (без опроса); таймер для тайм-аутов
/// работает только пока есть активные сессии.
public final class AgentEventsWatcher {
    public static let shared = AgentEventsWatcher()

    // Тайм-ауты состояний (секунды)
    private enum Timeout {
        static let promptToWorking: TimeInterval = 2.5
        // Тишина — не признак конца: долгая сборка или размышление молчат минутами. Esc в Claude не шлёт Stop,
        // поэтому прерывание ищем в транскрипте, а по одной тишине сессию только убираем (без «готово»).
        static let interruptCheck: TimeInterval = 15
        static let workingSilenceWithTranscript: TimeInterval = 1800
        static let workingSilence: TimeInterval = 600
        static let confirmationSilence: TimeInterval = 900
        static let doneVisible: TimeInterval = 6 * 3600   // done stays until the user has seen it (see startViewingAgentsTab)
        static let staleEvent: TimeInterval = 30
    }

    private let queue = DispatchQueue(label: "com.local.notchy.agenteventswatcher", qos: .utility)
    private let eventsURL = AppPaths.supportDir.appendingPathComponent("agent-events.jsonl")

    private var fileSource: DispatchSourceFileSystemObject?
    private var housekeeping: DispatchSourceTimer?
    private var offset: UInt64 = 0
    private var partialLine = Data()
    private var replaying = false
    private var sessions: [String: HookSessionTracker] = [:]

    private init() {}

    // MARK: - Lifecycle

    public func start() {
        queue.async { [weak self] in self?.openFile() }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.fileSource?.cancel()
            self?.fileSource = nil
            self?.stopHousekeeping()
            // Restarting replays the last minutes of the file: old sessions must not linger on top of that
            self?.sessions.removeAll()
        }
    }

    public func dismissSession(id: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.sessions.removeValue(forKey: id)
            self.publishInstances()
        }
    }

    public func dismissAllDoneSessions() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.sessions = self.sessions.filter { $0.value.workState != .done }
            self.publishInstances()
        }
    }

    public func removeSessions(for agent: AgentType) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.sessions = self.sessions.filter { $0.value.agent != agent }
            self.publishInstances()
        }
    }

    public func clearAllSessions() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.sessions.removeAll()
            self.publishInstances()
        }
    }

    // MARK: - File watching

    private func openFile() {
        fileSource?.cancel()
        fileSource = nil

        let path = eventsURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // Повторим позже, если каталог ещё недоступен
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.openFile() }
            return
        }

        // Старые события не воспроизводим, кроме последних минут: так сессии, которые шли в момент
        // (пере)запуска приложения, сразу появляются в челке, а не только после следующего события.
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        offset = replayOffset(size: size)
        replaying = offset < size
        partialLine.removeAll()

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self = self, let source = source else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Файл заменили/удалили — открываем заново
                self.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.openFile() }
                return
            }
            self.readNewEvents()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
        if replaying { readNewEvents() }
    }

    /// Смещение первой строки журнала, чьё событие не старше тайм-аута «молчащей» сессии.
    private func replayOffset(size: UInt64) -> UInt64 {
        let window: UInt64 = 512 * 1024
        let start = size > window ? size - window : 0
        guard let handle = try? FileHandle(forReadingFrom: eventsURL) else { return size }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return size }
        let cutoff = Date().timeIntervalSince1970 - Timeout.workingSilence
        let decoder = JSONDecoder()
        var pos = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            if let event = try? decoder.decode(RawHookEvent.self, from: Data(line)), let ts = event.ts, ts >= cutoff {
                return start + UInt64(pos)
            }
            pos += line.count + 1
        }
        return size
    }

    private func readNewEvents() {
        guard let handle = try? FileHandle(forReadingFrom: eventsURL) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {
            // Файл усечён
            offset = 0
            partialLine.removeAll()
        }
        guard size > offset else { replaying = false; return }

        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return }
            offset += UInt64(data.count)

            var buffer = partialLine
            buffer.append(data)
            var lines = buffer.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            // Последний фрагмент без перевода строки может быть неполным
            if buffer.last != UInt8(ascii: "\n"), let tail = lines.popLast() {
                partialLine = Data(tail)
            } else {
                partialLine.removeAll()
            }

            let decoder = JSONDecoder()
            let now = Date()
            var changed = false
            for line in lines {
                guard let event = try? decoder.decode(RawHookEvent.self, from: Data(line)) else { continue }
                let maxAge = replaying ? Timeout.workingSilence : Timeout.staleEvent
                if let ts = event.ts, now.timeIntervalSince1970 - ts > maxAge { continue }
                let eventTime = event.ts.map { Date(timeIntervalSince1970: $0) } ?? now
                if processRawEvent(event, timestamp: eventTime) { changed = true }
            }
            replaying = false
            if changed { publishInstances() }
        } catch {
            // Ошибка чтения — подхватим на следующем событии
        }
    }

    // MARK: - Event Processing

    private func resolveAgent(_ event: RawHookEvent, sessionId: String) -> AgentType {
        if let raw = event.lumio_agent, let agent = AgentType(hookName: raw) { return agent }
        // Префиксы session_id, которые ставит hook-скрипт для сторонних агентов
        if sessionId.hasPrefix("agy-") { return .antigravity }
        if sessionId.hasPrefix("gemini-") { return .gemini }
        if sessionId.hasPrefix("codex-") { return .codex }
        return .claude
    }

    /// Возвращает true, если список сессий изменился.
    @discardableResult
    private func processRawEvent(_ event: RawHookEvent, timestamp: Date) -> Bool {
        let sessionId = event.session_id ?? "unknown-session"
        let agent = resolveAgent(event, sessionId: sessionId)
        let eventName = event.hook_event_name ?? ""

        // Проект по корню сессии, а не по текущему cwd (он меняется после `cd`)
        let transcriptPath = event.transcript_path ?? sessions[sessionId]?.transcriptPath
        var rootCwd = sessions[sessionId]?.rootCwd ?? ""
        if let cwd = event.cwd, !cwd.isEmpty {
            if let root = Self.projectRoot(cwd: cwd, transcriptPath: transcriptPath) { rootCwd = root }
            else if rootCwd.isEmpty || rootCwd.hasPrefix(cwd + "/") { rootCwd = cwd }
        }
        var projectName = ""
        if !rootCwd.isEmpty {
            let last = URL(fileURLWithPath: rootCwd).lastPathComponent
            projectName = (last.isEmpty || last == "/") ? "~" : last
        }
        if projectName.isEmpty { projectName = sessions[sessionId]?.projectName ?? "" }

        if let aid = event.agent_id, !aid.isEmpty, var t = sessions[sessionId] {
            if eventName == "SubagentStop" { t.subagentSeen.removeValue(forKey: aid) } else { t.subagentSeen[aid] = timestamp }
            sessions[sessionId] = t
        }

        switch eventName {
        case "SessionEnd":
            return sessions.removeValue(forKey: sessionId) != nil
        case "SessionStart":
            return false
        case "SubagentStart":
            guard var tracker = sessions[sessionId] else { return false }
            tracker.subagentCount += 1
            tracker.lastUpdate = timestamp
            sessions[sessionId] = tracker
            return true
        case "SubagentStop":
            guard var tracker = sessions[sessionId] else { return false }
            tracker.subagentCount = max(0, tracker.subagentCount - 1)
            tracker.lastUpdate = timestamp
            sessions[sessionId] = tracker
            return true
        default:
            break
        }

        var targetState: WorkState
        var question: String? = nil
        var completedDate: Date? = nil

        switch eventName {
        case "UserPromptSubmit", "PreInvocation", "BeforeAgent", "beforeSubmitPrompt":
            targetState = .promptReceived
        case "Stop", "AfterAgent", "StopFailure", "TurnAborted":
            // Субагенты ещё работают (фоновые): главный агент закончил ход, но задача не готова
            if var t = sessions[sessionId], !t.subagentSeen.isEmpty, eventName == "Stop" {
                t.deferredStop = timestamp
                t.lastUpdate = timestamp
                sessions[sessionId] = t
                return false
            } else {
                targetState = .done
                completedDate = timestamp
            }
        case "PermissionRequest":
            targetState = .needsConfirmation
            question = event.lumio_question ?? event.message
        case "Notification":
            switch event.notification_type ?? "" {
            case "permission_prompt", "agent_needs_input", "ToolPermission", "elicitation_dialog":
                targetState = .needsConfirmation
                question = event.lumio_question ?? event.message
            case "idle_prompt":
                // Агент давно ждёт пользователя — работа закончена
                targetState = .done
                completedDate = timestamp
            default:
                // Прочие уведомления не меняют состояние, но подтверждают, что сессия жива
                guard var tracker = sessions[sessionId] else { return false }
                tracker.lastUpdate = timestamp
                sessions[sessionId] = tracker
                return false
            }
        default:
            // PreToolUse / PostToolUse и любые другие события работы
            targetState = .working
        }

        // Событие инструмента, пришедшее после Stop (асинхронные хуки), не должно оживлять завершённую сессию
        if targetState == .working, let existing = sessions[sessionId], existing.workState == .done,
           let done = existing.completedAt, timestamp <= done {
            return false
        }
        // Сессия, о которой мы знаем только по "Stop", но которая не работала — не показываем
        if targetState == .done && sessions[sessionId] == nil { return false }

        var tracker = sessions[sessionId] ?? HookSessionTracker(
            id: sessionId, agent: agent, projectName: projectName,
            workState: targetState, lastUpdate: timestamp
        )
        tracker.agent = agent
        if !projectName.isEmpty { tracker.projectName = projectName }
        tracker.rootCwd = rootCwd
        tracker.transcriptPath = transcriptPath
        tracker.workState = targetState
        tracker.statusDescription = question
        tracker.lastUpdate = timestamp
        if let completedDate = completedDate {
            tracker.completedAt = completedDate
            tracker.subagentCount = 0
            tracker.subagentSeen = [:]
        } else {
            tracker.completedAt = nil
            tracker.hasBeenSeen = false
        }
        // События субагентов не отменяют отложенный Stop главного агента
        if (event.agent_id ?? "").isEmpty { tracker.deferredStop = nil }
        sessions[sessionId] = tracker
        startHousekeepingIfNeeded()
        return true
    }

    // MARK: - Timeouts (таймер живёт только пока есть сессии)

    private func startHousekeepingIfNeeded() {
        guard housekeeping == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.expireSessions() { self.publishInstances() }
            if self.sessions.isEmpty { self.stopHousekeeping() }
        }
        timer.resume()
        housekeeping = timer
    }

    private func stopHousekeeping() {
        housekeeping?.cancel()
        housekeeping = nil
    }

    private func expireSessions() -> Bool {
        let now = Date()
        var changed = false
        for (id, var tracker) in sessions {
            let before = tracker.subagentSeen.count
            tracker.subagentSeen = tracker.subagentSeen.filter { now.timeIntervalSince($0.value) < 25 }
            if tracker.subagentSeen.count != before { sessions[id] = tracker; changed = true }
            if let stop = tracker.deferredStop, tracker.subagentSeen.isEmpty {
                tracker.workState = .done
                tracker.completedAt = stop
                tracker.lastUpdate = now
                tracker.deferredStop = nil
                tracker.subagentCount = 0
                sessions[id] = tracker
                changed = true
                continue
            }
            let elapsed = now.timeIntervalSince(tracker.lastUpdate)
            switch tracker.workState {
            case .promptReceived where elapsed > Timeout.promptToWorking:
                tracker.workState = .working
                sessions[id] = tracker
                changed = true
            case .working where elapsed > Timeout.interruptCheck:
                // Без «готово» и уведомления: работу не закончили, её прервали или сессия пропала
                let interrupted = tracker.transcriptPath.map { Int(elapsed) % 5 == 0 && Self.lastTurnInterrupted($0) } ?? false
                let limit = tracker.transcriptPath == nil ? Timeout.workingSilence : Timeout.workingSilenceWithTranscript
                if interrupted || (elapsed > limit && Self.transcriptIdle(tracker.transcriptPath, for: limit)) {
                    sessions.removeValue(forKey: id)
                    changed = true
                }
            case .needsConfirmation where elapsed > Timeout.confirmationSilence:
                sessions.removeValue(forKey: id)
                changed = true
            case .done where elapsed > Timeout.doneVisible:
                sessions.removeValue(forKey: id)
                changed = true
            default:
                break
            }
        }
        return changed
    }

    // MARK: - Transcript

    /// Claude хранит транскрипт в ~/.claude/projects/<корень проекта, где всё кроме букв и цифр заменено на «-»>/.
    /// Ищем среди cwd и его родителей папку, которая так кодируется.
    static func projectRoot(cwd: String, transcriptPath: String?) -> String? {
        guard let tp = transcriptPath else { return nil }
        let encoded = URL(fileURLWithPath: tp).deletingLastPathComponent().lastPathComponent
        func encode(_ p: String) -> String { String(p.map { $0.isLetter || $0.isNumber ? $0 : "-" }) }
        var dir = cwd
        while !dir.isEmpty && dir != "/" {
            if encode(dir) == encoded { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Последняя реплика в транскрипте — «[Request interrupted by user…]» (Esc), после которого Stop не приходит.
    static func lastTurnInterrupted(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        h.seek(toFileOffset: size > 65536 ? size - 65536 : 0)
        let data = h.readDataToEndOfFile()
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant" else { continue }
            // Только текст самого сообщения: в выводе инструментов эта фраза тоже может встретиться
            let content = (obj["message"] as? [String: Any])?["content"]
            let texts = (content as? String).map { [$0] }
                ?? (content as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            return texts.contains { $0.hasPrefix("[Request interrupted by user") }
        }
        return false
    }

    /// Транскрипт не менялся `seconds` секунд (или его нет): агент точно не работает.
    static func transcriptIdle(_ path: String?, for seconds: TimeInterval) -> Bool {
        guard let path = path, let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mod = attrs[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(mod) > seconds
    }

    // MARK: - Publish

    private static func priority(_ state: WorkState) -> Int {
        switch state {
        case .needsConfirmation: return 4
        case .working: return 3
        case .promptReceived: return 2
        case .done: return 1
        case .idle: return 0
        }
    }

    private func publishInstances() {
        // Одна строка на пару «агент + проект»: берём самую значимую, затем самую свежую сессию
        var unique: [String: HookSessionTracker] = [:]
        for tracker in sessions.values where tracker.workState != .idle {
            let key = "\(tracker.agent.rawValue):\(tracker.projectName)"
            if let existing = unique[key] {
                let (p1, p2) = (Self.priority(tracker.workState), Self.priority(existing.workState))
                if p1 > p2 || (p1 == p2 && tracker.lastUpdate > existing.lastUpdate) {
                    unique[key] = tracker
                }
            } else {
                unique[key] = tracker
            }
        }

        let active = unique.values
            .map { s in
                AgentInstance(
                    id: s.id,
                    agent: s.agent,
                    projectName: s.projectName,
                    workState: s.workState,
                    statusDescription: s.statusDescription,
                    hasBeenSeen: s.hasBeenSeen,
                    completedAt: s.completedAt,
                    subagentCount: s.activeSubagents
                )
            }
            .sorted { ($0.agent.rawValue, $0.projectName) < ($1.agent.rawValue, $1.projectName) }

        AgentStatusService.shared.setHookInstances(active)
    }
}

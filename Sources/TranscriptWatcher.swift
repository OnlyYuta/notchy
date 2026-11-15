import Foundation
import SwiftUI
import SQLite3

// MARK: - Per-Session State Tracker

private struct SessionStateTracker {
    var state: WorkState = .idle
    var project: String = ""
    var isSubagent: Bool = false
    var parentProject: String = ""
    var lastUpdate: Date = Date()
    var lastStepType: String = ""
    var lastStepHadTools: Bool = false
    var lastStepHasContent: Bool = false
    var pendingConfirmation: Bool = false
    var hasPendingToolCall: Bool = false
    var promptTimestamp: Date = .distantPast
}

public final class TranscriptWatcher {
    public static let shared = TranscriptWatcher()
    
    private let queue = DispatchQueue(label: "com.local.notchy.transcriptwatcher")
    private var timer: Timer?
    private var fileOffsets: [String: UInt64] = [:]
    private var lineBuffers: [String: String] = [:]
    
    // Per-session tracking: convId -> SessionStateTracker
    private var sessionTrackers: [String: SessionStateTracker] = [:]
    private var sessionWorkItems: [String: DispatchWorkItem] = [:]
    private var cachedProjects: [String: String] = [:]
    
    private var candidateBrainDirs: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".gemini/antigravity/brain").path,
            home.appendingPathComponent(".gemini/antigravity-cli/brain").path,
            home.appendingPathComponent("Library/Application Support/Antigravity/brain").path,
            home.appendingPathComponent(".antigravity/brain").path,
            home.appendingPathComponent(".config/antigravity/brain").path
        ]
    }
    
    private var candidateDbPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".gemini/antigravity/conversation_summaries.db").path,
            home.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db").path,
            home.appendingPathComponent("Library/Application Support/Antigravity/conversation_summaries.db").path,
            home.appendingPathComponent(".antigravity/conversation_summaries.db").path,
            home.appendingPathComponent(".config/antigravity/conversation_summaries.db").path
        ]
    }
    
    private init() {}
    
    public func start() {
        timer?.invalidate()
        queue.async { [weak self] in
            self?.warmup()
        }
        // Poll every 1.2s for crisp real-time responsiveness with near zero CPU
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
        timer?.tolerance = 0.5
    }
    
    public func stop() {
        timer?.invalidate()
        timer = nil
        queue.async { [weak self] in
            guard let self = self else { return }
            for (_, item) in self.sessionWorkItems {
                item.cancel()
            }
            self.sessionWorkItems.removeAll()
        }
    }
    
    // MARK: - Project Resolution
    
    private func parseProjectFromUris(_ uris: String) -> String? {
        let trimmed = uris.trimmingCharacters(in: CharacterSet(charactersIn: "[]\"' "))
        for item in trimmed.components(separatedBy: ",") {
            var clean = item.trimmingCharacters(in: CharacterSet(charactersIn: "\"'/ "))
            if clean.hasPrefix("file://") {
                clean = String(clean.dropFirst(7))
            } else if clean.hasPrefix("file:") {
                clean = String(clean.dropFirst(5))
            }
            clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            if !clean.isEmpty && clean != "file:" && !clean.contains(".gemini") && !clean.contains("brain") {
                let parts = clean.components(separatedBy: "/").filter { !$0.isEmpty }
                if let name = parts.last, !name.isEmpty, name != "Desktop", name != "Users", name != "file:", (!name.contains("-") || name.count < 35) {
                    return name
                }
            }
        }
        return nil
    }
    
    private func extractProjectFromTranscriptFile(_ path: String) -> String? {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fileHandle.close() }
        
        let headerData = fileHandle.readData(ofLength: 8192)
        guard let text = String(data: headerData, encoding: .utf8) else { return nil }
        
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            if let proj = extractProjectName(from: json) {
                return proj
            }
        }
        return nil
    }
    
    private func resolveProjectName(for convId: String) -> String {
        if let cached = cachedProjects[convId], !cached.isEmpty {
            return cached
        }
        
        // 1. Query candidate conversation_summaries.db
        for dbPath in candidateDbPaths {
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
                sqlite3_busy_timeout(db, 500)
                var stmt: OpaquePointer?
                let sql = "SELECT workspace_uris FROM conversation_summaries WHERE conversation_id = ? LIMIT 1"
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (convId as NSString).utf8String, -1, nil)
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        if let urisText = sqlite3_column_text(stmt, 0) {
                            let rawUris = String(cString: urisText)
                            if let proj = parseProjectFromUris(rawUris) {
                                cachedProjects[convId] = proj
                                sqlite3_finalize(stmt)
                                sqlite3_close(db)
                                return proj
                            }
                        }
                    }
                    sqlite3_finalize(stmt)
                }
                sqlite3_close(db)
            }
        }
        
        // 2. Fallback: inspect the transcript header or tool calls across all candidate brain dirs
        for brainDir in candidateBrainDirs {
            let transcriptPath = "\(brainDir)/\(convId)/.system_generated/logs/transcript.jsonl"
            if FileManager.default.fileExists(atPath: transcriptPath),
               let proj = extractProjectFromTranscriptFile(transcriptPath) {
                cachedProjects[convId] = proj
                return proj
            }
        }
        
        return ""
    }
    
    private func findActiveSessions() -> [(convId: String, path: String, project: String, isRunning: Bool, modDate: Date, isSubagent: Bool, parentProject: String)] {
        var sessions: [String: (path: String, project: String, isRunning: Bool, modDate: Date, isSubagent: Bool, parentProject: String)] = [:]
        
        // 1. Check candidate conversation_summaries.db for recent top-level user conversations and active subagents
        for dbPath in candidateDbPaths {
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
                sqlite3_busy_timeout(db, 500)
                var stmt: OpaquePointer?
                let sql = "SELECT conversation_id, workspace_uris, status, not_fully_idle, killed, last_modified_time, agent_name, nesting_depth FROM conversation_summaries WHERE (not_fully_idle = 1 OR status = 'CASCADE_RUN_STATUS_RUNNING') ORDER BY last_modified_time DESC LIMIT 10"
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        guard let col0 = sqlite3_column_text(stmt, 0) else { continue }
                        let convId = String(cString: col0)
                        let uris = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
                        let status = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
                        let notFullyIdle = sqlite3_column_int(stmt, 3) != 0
                        let killed = sqlite3_column_int(stmt, 4) != 0
                        let isRunning = !killed && (notFullyIdle || status == "CASCADE_RUN_STATUS_RUNNING")
                        let nestingDepth = sqlite3_column_int(stmt, 7)
                        
                        let baseProj = parseProjectFromUris(uris) ?? ""
                        let isSub = nestingDepth > 0
                        if isSub && !isRunning {
                            continue
                        }
                        let proj = baseProj.isEmpty ? "Antigravity" : baseProj
                        let parentProj = proj
                        
                        for brainDir in candidateBrainDirs {
                            let path = "\(brainDir)/\(convId)/.system_generated/logs/transcript.jsonl"
                            if FileManager.default.fileExists(atPath: path),
                               let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                               let modDate = attrs[.modificationDate] as? Date {
                                if sessions[convId] == nil {
                                    sessions[convId] = (path, proj, isRunning, modDate, isSub, parentProj)
                                    if !proj.isEmpty { cachedProjects[convId] = proj }
                                }
                                break
                            }
                        }
                    }
                    sqlite3_finalize(stmt)
                }
                sqlite3_close(db)
            }
        }
        

        
        return sessions.map { ($0.key, $0.value.path, $0.value.project, $0.value.isRunning, $0.value.modDate, $0.value.isSubagent, $0.value.parentProject) }
    }
    
    private func stepHasToolCalls(_ json: [String: Any]) -> Bool {
        if let toolCalls = json["tool_calls"] as? [Any], !toolCalls.isEmpty {
            return true
        }
        if let truncated = json["truncated_fields"] as? [String], truncated.contains("tool_calls") {
            return true
        }
        return false
    }
    
    private func isTruthy(_ value: Any?) -> Bool {
        guard let value = value else { return false }
        if let b = value as? Bool { return b }
        if let s = value as? String {
            let clean = s.trimmingCharacters(in: CharacterSet(charactersIn: "\" '")).lowercased()
            return clean == "true" || clean == "1" || clean == "yes"
        }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }
    
    private func stepRequestsConfirmation(_ json: [String: Any]) -> Bool {
        guard let toolCalls = json["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty else {
            return false
        }
        for call in toolCalls {
            let name = ((call["name"] as? String) ?? (call["toolName"] as? String) ?? "").lowercased()
            if name.contains("ask_question") || name.contains("confirm") || name.contains("approval") {
                return true
            }
            var args = (call["args"] as? [String: Any]) ?? (call["arguments"] as? [String: Any]) ?? [:]
            if args.isEmpty {
                if let argsStr = (call["args"] as? String) ?? (call["arguments"] as? String),
                   let data = argsStr.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    args = parsed
                }
            }
            var metaDict = args["ArtifactMetadata"] as? [String: Any]
            if metaDict == nil, let metaStr = args["ArtifactMetadata"] as? String,
               let data = metaStr.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                metaDict = parsed
            }
            if let meta = metaDict, isTruthy(meta["RequestFeedback"]) {
                return true
            }
        }
        return false
    }
    
    private func extractProjectName(from json: [String: Any]) -> String? {
        if let toolCalls = json["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                if let args = call["args"] as? [String: Any] {
                    for key in ["Cwd", "DirectoryPath", "SearchDirectory"] {
                        if let dir = args[key] as? String {
                            let trimmed = dir.trimmingCharacters(in: CharacterSet(charactersIn: "\"'/"))
                            if !trimmed.contains(".gemini") && !trimmed.contains("brain") {
                                if let name = trimmed.components(separatedBy: "/").last,
                                   !name.isEmpty && name != "Desktop" && name != "Users" && (!name.contains("-") || name.count < 35) {
                                    return name
                                }
                            }
                        }
                    }
                    if let targetFile = args["TargetFile"] as? String {
                        let trimmed = targetFile.trimmingCharacters(in: CharacterSet(charactersIn: "\"'/"))
                        if !trimmed.contains(".gemini") && !trimmed.contains("brain") {
                            for marker in ["/Desktop/", "/Projects/", "/Developer/", "/Workspace/"] {
                                if let range = trimmed.range(of: marker) {
                                    let sub = trimmed[range.upperBound...]
                                    if let proj = sub.components(separatedBy: "/").first, !proj.isEmpty {
                                        return proj
                                    }
                                }
                            }
                            let parts = trimmed.components(separatedBy: "/")
                            if parts.count >= 2 {
                                let folder = parts[parts.count - 2]
                                let ignored: Set<String> = ["Sources", "src", "lib", "Pods", "Tests", "build", ".build", "DerivedData"]
                                if !folder.isEmpty && !ignored.contains(folder) && (!folder.contains("-") || folder.count < 35) {
                                    return folder
                                }
                            }
                        }
                    }
                }
            }
        }
        return nil
    }
    
    private var lastRunningCheckTime: Date = .distantPast
    private var cachedIsRunning: Bool = false
    private var lastPublishedInstances: [AgentInstance] = []
    
    private func isAntigravityRunning() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastRunningCheckTime) < 2.0 {
            return cachedIsRunning
        }
        lastRunningCheckTime = now
        
        // Bundle id only: NSRunningApplication.localizedName is an expensive per-app lookup
        let appRunning = NSWorkspace.shared.runningApplications.contains { app in
            let bid = (app.bundleIdentifier ?? "").lowercased()
            return bid.contains("antigravity") || bid.contains("gemini")
        }
        cachedIsRunning = appRunning
        return appRunning
    }
    
    public func clearAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.sessionTrackers.removeAll()
            self.lineBuffers.removeAll()
            self.lastPublishedInstances = []
            AgentStatusService.shared.setAntigravityInstances([])
        }
    }
    
    private func publishAggregateState() {
        guard isAntigravityRunning() else {
            if !lastPublishedInstances.isEmpty || !sessionTrackers.isEmpty {
                sessionTrackers.removeAll()
                lastPublishedInstances = []
                AgentStatusService.shared.setAntigravityInstances([])
            }
            return
        }
        
        // 1. Count active subagents by parent project
        var subagentCounts: [String: Int] = [:]
        for (_, tracker) in sessionTrackers {
            if tracker.isSubagent && (tracker.state == .working || tracker.state == .promptReceived) {
                let parent = tracker.parentProject.isEmpty ? tracker.project : tracker.parentProject
                subagentCounts[parent, default: 0] += 1
            }
        }
        
        // 2. Build instances for top-level (main) projects
        var mainInstancesByProject: [String: AgentInstance] = [:]
        for (convId, tracker) in sessionTrackers {
            if !tracker.isSubagent && tracker.state != .idle {
                let proj = tracker.project.isEmpty ? "Antigravity" : tracker.project
                let instId = "antigravity-\(proj)-\(convId.prefix(8))"
                let count = subagentCounts[proj] ?? 0
                mainInstancesByProject[proj] = AgentInstance(
                    id: instId,
                    agent: .antigravity,
                    projectName: proj,
                    workState: tracker.state,
                    hasBeenSeen: false,
                    completedAt: tracker.state == .done ? tracker.lastUpdate : nil,
                    subagentCount: count
                )
            }
        }
        
        // 3. For any parent project that has active subagents but whose main session is idle or absent:
        for (proj, count) in subagentCounts where count > 0 {
            if mainInstancesByProject[proj] == nil {
                let instId = "antigravity-\(proj)-subagents"
                mainInstancesByProject[proj] = AgentInstance(
                    id: instId,
                    agent: .antigravity,
                    projectName: proj,
                    workState: .working,
                    hasBeenSeen: false,
                    completedAt: nil,
                    subagentCount: count
                )
            }
        }
        
        var agyInstances = Array(mainInstancesByProject.values)
        
        // Sort: needsConfirmation first, then working, then alphabetical
        agyInstances.sort { a, b in
            if a.workState == .needsConfirmation && b.workState != .needsConfirmation { return true }
            if a.workState != .needsConfirmation && b.workState == .needsConfirmation { return false }
            if a.workState == .working && b.workState != .working { return true }
            if a.workState != .working && b.workState == .working { return false }
            return a.projectName < b.projectName
        }
        
        if agyInstances == lastPublishedInstances {
            return
        }
        lastPublishedInstances = agyInstances
        AgentStatusService.shared.setAntigravityInstances(agyInstances)
    }
    
    public func dismissAllDoneSessions() {
        queue.async { [weak self] in
            guard let self = self else { return }
            for (convId, var tracker) in self.sessionTrackers {
                if tracker.state == .done {
                    tracker.state = .idle
                    self.sessionTrackers[convId] = tracker
                }
            }
            self.publishAggregateState()
        }
    }
    
    public func dismissSession(convId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if var tracker = self.sessionTrackers[convId] {
                tracker.state = .idle
                self.sessionTrackers[convId] = tracker
                self.publishAggregateState()
            }
        }
    }
    
    private func updateSessionState(convId: String, newState: WorkState, project: String) {
        if var tracker = sessionTrackers[convId] {
            if tracker.state == newState && tracker.project == project {
                return
            }
            tracker.state = newState
            tracker.project = project
            tracker.lastUpdate = Date()
            sessionTrackers[convId] = tracker
        } else {
            sessionTrackers[convId] = SessionStateTracker(
                state: newState,
                project: project,
                lastUpdate: Date()
            )
        }
        
        sessionWorkItems[convId]?.cancel()
        sessionWorkItems[convId] = nil
        
        publishAggregateState()
        
        if newState == .promptReceived {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.queue.async {
                    if self.sessionTrackers[convId]?.state == .promptReceived {
                        self.updateSessionState(convId: convId, newState: .working, project: project)
                    }
                }
            }
            sessionWorkItems[convId] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        } else if newState == .done {
            // Safety fallback: if the user never opens the notch for 6 hours, auto-expire
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.queue.async {
                    if self.sessionTrackers[convId]?.state == .done {
                        self.updateSessionState(convId: convId, newState: .idle, project: project)
                    }
                }
            }
            sessionWorkItems[convId] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6 * 3600, execute: work)
        }
    }
    
    private func warmup() {
        let active = findActiveSessions()
        for session in active {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: session.path),
                  let fileSize = attrs[.size] as? UInt64 else { continue }
            
            fileOffsets[session.path] = fileSize
            
            // Tail scan (up to 32KB) to find the latest valid step
            guard let fileHandle = FileHandle(forReadingAtPath: session.path) else { continue }
            let tailLength: UInt64 = min(fileSize, 32768)
            let offset = fileSize - tailLength
            try? fileHandle.seek(toOffset: offset)
            if let data = try? fileHandle.readToEnd(),
               let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                
                var latestStep: [String: Any]? = nil
                for line in lines.reversed() {
                    guard let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                        continue
                    }
                    let t = json["type"] as? String ?? ""
                    if t == "PLANNER_RESPONSE" || t == "USER_INPUT" || t == "GENERIC" {
                        latestStep = json
                        break
                    }
                }
                
                if let step = latestStep {
                    let type = step["type"] as? String ?? ""
                    let proj = extractProjectName(from: step) ?? session.project
                    let hasTools = stepHasToolCalls(step)
                    let requestsConfirm = stepRequestsConfirmation(step)
                    let content = (step["content"] as? String) ?? ""
                    let hasContent = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    
                    let pendingConfirm = requestsConfirm
                    var tracker = SessionStateTracker(
                        state: .idle,
                        project: proj,
                        isSubagent: session.isSubagent,
                        parentProject: session.parentProject,
                        lastUpdate: Date(),
                        lastStepType: type,
                        lastStepHadTools: hasTools,
                        lastStepHasContent: hasContent,
                        pendingConfirmation: pendingConfirm,
                        hasPendingToolCall: hasTools && !requestsConfirm
                    )
                    
                    if pendingConfirm {
                        tracker.state = .needsConfirmation
                    } else if session.isRunning {
                        if type == "PLANNER_RESPONSE" && !hasTools && hasContent {
                            let timeSinceMod = Date().timeIntervalSince(session.modDate)
                            if timeSinceMod < 60.0 {
                                tracker.state = .done
                            } else {
                                tracker.state = .idle
                            }
                        } else {
                            tracker.state = .working
                        }
                    } else {
                        tracker.state = .idle
                    }
                    sessionTrackers[session.convId] = tracker
                }
            }
            try? fileHandle.close()
        }
        
        publishAggregateState()
    }
    
    private func checkForUpdates() {
        queue.async { [weak self] in
            guard let self = self else { return }
            // Приложение не запущено — не сканируем диск вовсе
            guard self.isAntigravityRunning() else {
                self.publishAggregateState()
                return
            }
            let active = self.findActiveSessions()
            
            let activeConvIds = Set(active.map { $0.convId })
            for (convId, var tracker) in self.sessionTrackers {
                if !activeConvIds.contains(convId) && tracker.state != .idle {
                    tracker.state = .idle
                    self.sessionTrackers[convId] = tracker
                }
            }
            
            for session in active {
                if var tracker = self.sessionTrackers[session.convId] {
                    tracker.isSubagent = session.isSubagent
                    tracker.parentProject = session.parentProject
                    self.sessionTrackers[session.convId] = tracker
                }
                
                let path = session.path
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let fileSize = attrs[.size] as? UInt64 else { continue }
                
                let currentOffset: UInt64
                if let saved = self.fileOffsets[path] {
                    currentOffset = (fileSize < saved) ? 0 : saved
                } else {
                    let readTail: UInt64 = min(fileSize, 65536)
                    currentOffset = fileSize - readTail
                }
                
                if fileSize > currentOffset {
                    guard let fileHandle = FileHandle(forReadingAtPath: path) else { continue }
                    try? fileHandle.seek(toOffset: currentOffset)
                    let bytesToRead = Int(fileSize - currentOffset)
                    let data = fileHandle.readData(ofLength: bytesToRead)
                    try? fileHandle.close()
                    
                    self.fileOffsets[path] = currentOffset + UInt64(data.count)
                    
                    if let chunk = String(data: data, encoding: .utf8) {
                        var buffer = self.lineBuffers[path] ?? ""
                        buffer.append(chunk)
                        
                        let lines = buffer.components(separatedBy: "\n")
                        self.lineBuffers[path] = lines.last ?? ""
                        
                        let completedLines = lines.dropLast()
                        for line in completedLines {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty,
                                  let lineData = trimmed.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                                continue
                            }
                            self.processStep(json, convId: session.convId, path: path, defaultProject: session.project)
                        }
                    }
                }
                
                self.evaluateCompletion(session: session)
            }
        }
    }
    
    private func processStep(_ json: [String: Any], convId: String, path: String, defaultProject: String) {
        let type = json["type"] as? String ?? ""
        var tracker = sessionTrackers[convId] ?? SessionStateTracker(project: defaultProject)
        
        let existingProj = tracker.project
        let proj: String
        if existingProj.contains("(") {
            proj = existingProj
        } else {
            proj = extractProjectName(from: json) ?? existingProj
        }
        tracker.project = proj
        tracker.lastStepType = type
        
        if type == "USER_INPUT" {
            tracker.promptTimestamp = Date()
            tracker.lastStepHadTools = false
            tracker.lastStepHasContent = false
            tracker.pendingConfirmation = false
            tracker.hasPendingToolCall = false
            sessionTrackers[convId] = tracker
            updateSessionState(convId: convId, newState: .promptReceived, project: proj)
            
        } else if type == "PLANNER_RESPONSE" {
            let hasTools = stepHasToolCalls(json)
            tracker.lastStepHadTools = hasTools
            
            if hasTools {
                tracker.lastStepHasContent = false
                if stepRequestsConfirmation(json) {
                    tracker.pendingConfirmation = true
                    tracker.hasPendingToolCall = false
                    sessionTrackers[convId] = tracker
                    updateSessionState(convId: convId, newState: .needsConfirmation, project: proj)
                } else {
                    tracker.pendingConfirmation = false
                    tracker.hasPendingToolCall = true
                    sessionTrackers[convId] = tracker
                    updateSessionState(convId: convId, newState: .working, project: proj)
                }
            } else {
                let content = (json["content"] as? String) ?? ""
                let hasContent = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                tracker.lastStepHasContent = hasContent
                tracker.pendingConfirmation = false
                tracker.hasPendingToolCall = false
                sessionTrackers[convId] = tracker
                
                if hasContent {
                    // Turn finished! The agent responded to the user!
                    updateSessionState(convId: convId, newState: .done, project: proj)
                } else {
                    if tracker.state != .working && tracker.state != .promptReceived {
                        updateSessionState(convId: convId, newState: .working, project: proj)
                    }
                }
            }
            
        } else if type == "GENERIC" {
            // Tool execution output returned!
            tracker.lastStepHadTools = false
            tracker.hasPendingToolCall = false
            tracker.pendingConfirmation = false // Any pending confirmation was approved and completed!
            sessionTrackers[convId] = tracker
            updateSessionState(convId: convId, newState: .working, project: proj)
        } else {
            sessionTrackers[convId] = tracker
        }
    }
    
    private func evaluateCompletion(session: (convId: String, path: String, project: String, isRunning: Bool, modDate: Date, isSubagent: Bool, parentProject: String)) {
        guard let tracker = sessionTrackers[session.convId] else { return }
        let currentState = tracker.state
        
        // 1. If this session is not running according to SQLite (killed or idle):
        if !session.isRunning {
            if currentState != .idle {
                updateSessionState(convId: session.convId, newState: .idle, project: tracker.project)
            }
            return
        }
        
        // 2. If currently waiting for user confirmation, IT MUST STAY in .needsConfirmation!
        if tracker.pendingConfirmation {
            if currentState != .needsConfirmation {
                updateSessionState(convId: session.convId, newState: .needsConfirmation, project: tracker.project)
            }
            return
        }
        
        // 3. If a tool was called and is executing, or tool output was just returned (GENERIC), or user input just received: MUST remain in .working
        if tracker.hasPendingToolCall || tracker.lastStepType == "GENERIC" || tracker.lastStepType == "USER_INPUT" {
            if currentState != .working && currentState != .promptReceived {
                updateSessionState(convId: session.convId, newState: .working, project: tracker.project)
            }
            return
        }
        
        // 4. If latest step is PLANNER_RESPONSE without tools and has content:
        // THE TURN IS COMPLETE! Only transition to .done if we were working or prompt was received.
        if tracker.lastStepType == "PLANNER_RESPONSE" && !tracker.lastStepHadTools && tracker.lastStepHasContent {
            if currentState == .working || currentState == .promptReceived {
                updateSessionState(convId: session.convId, newState: .done, project: tracker.project)
            }
            return
        }
        
        // 5. Inactive session fallback: if idle for over 60s
        let timeSinceMod = Date().timeIntervalSince(session.modDate)
        if timeSinceMod > 60.0 && currentState == .working {
            updateSessionState(convId: session.convId, newState: .idle, project: tracker.project)
        }
    }
}

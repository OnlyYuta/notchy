import Foundation
import SwiftUI
import Combine
import Darwin

public final class AgentStatusService: ObservableObject {
    public static let shared = AgentStatusService()
    
    @Published public private(set) var activeAgents: [AgentType] = [.antigravity]
    @Published public private(set) var currentAgent: AgentType = .antigravity
    @Published public private(set) var currentProject: String = ""
    @Published public private(set) var workingAgents: [AgentType] = []
    @Published public private(set) var instances: [AgentInstance] = []
    @Published public private(set) var workState: WorkState = .idle
    @Published public var requestedTab: String? = nil
    @Published public private(set) var isAnyAgentAppRunning: Bool = false
    /// Открытые GUI-приложения агентов (только те, чей показ включён), даже если агент сейчас ничего не делает.
    @Published public private(set) var runningAgents: [AgentType] = []
    
    private let agentsFilePath = AppPaths.ipcDir.appendingPathComponent("agents.json").path
    private let statusFilePath = AppPaths.ipcDir.appendingPathComponent("status.json").path
    private var lastAgentsModDate: Date?
    private var lastStatusModDate: Date?
    
    private var antigravityInstances: [AgentInstance] = []
    private var externalInstances: [AgentInstance] = []
    private var hookInstances: [AgentInstance] = []
    
    private var pollTimer: Timer?
    private var agentsTabDwellTimer: DispatchWorkItem?
    private var instanceRetractWorkItems: [String: DispatchWorkItem] = [:]
    
    /// The Agents tab switched off: no file polling or process scans, and no leftover "working" state in the wings
    public func setEnabled(_ on: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        if on {
            startPolling()
            refreshCLIAgents()
        } else {
            instances = []
            workingAgents = []
            cliSessions = []
            workState = .idle
        }
    }
    
    public init() {
        syncAgentsToFile()
        syncStatusToFile()
        startPolling()
        setupAppLifecycleObservers()
        refreshCLIAgents()
    }
    
    deinit {
        pollTimer?.invalidate()
        agentsTabDwellTimer?.cancel()
        for (_, item) in instanceRetractWorkItems {
            item.cancel()
        }
        instanceRetractWorkItems.removeAll()
    }
    
    public static let springAnimation: Animation = .spring(response: 0.40, dampingFraction: 0.82)
    
    // Effective list of currently working agent instances
    public var workingInstances: [AgentInstance] {
        if !instances.isEmpty {
            let working = instances.filter { $0.workState != .idle }
            if !working.isEmpty {
                return working
            }
        }
        if workState == .working || workState == .promptReceived {
            return [AgentInstance(id: "\(currentAgent.rawValue)-\(currentProject)", agent: currentAgent, projectName: currentProject, workState: workState)]
        }
        return []
    }
    
    // MARK: - WorkState & Instance Management
    
    public func setHookInstances(_ list: [AgentInstance]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.hookInstances != list else { return }
            self.hookInstances = list
            self.recalculateCombinedInstances()
        }
    }
    
    public func setAntigravityInstances(_ list: [AgentInstance]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.antigravityInstances != list else { return }
            self.antigravityInstances = list
            self.recalculateCombinedInstances()
        }
    }
    
    public func setExternalInstances(_ list: [AgentInstance]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.externalInstances != list else { return }
            self.externalInstances = list
            self.recalculateCombinedInstances()
        }
    }
    
    /// Перечитывает список после включения/выключения показа агента.
    public func refreshAgentFilter() {
        DispatchQueue.main.async { [weak self] in
            self?.recalculateCombinedInstances()
            self?.checkRunningAgentApps()
        }
    }
    
    private func recalculateCombinedInstances() {
        let rawCombined: [AgentInstance]
        if !self.hookInstances.isEmpty {
            var merged = self.hookInstances
            for inst in self.externalInstances {
                if !merged.contains(where: { $0.agent == inst.agent && $0.projectName == inst.projectName }) {
                    merged.append(inst)
                }
            }
            for inst in self.antigravityInstances {
                if !merged.contains(where: { $0.agent == inst.agent && $0.projectName == inst.projectName }) {
                    merged.append(inst)
                }
            }
            rawCombined = merged
        } else if self.antigravityInstances.isEmpty {
            rawCombined = self.externalInstances
        } else {
            let nonAgyExternal = self.externalInstances.filter { $0.agent != .antigravity }
            rawCombined = self.antigravityInstances + nonAgyExternal
        }
        // Агенты, чей показ выключен пользователем, в челке не отображаются
        let combined = rawCombined.filter { AgentHookManager.shared.isEnabled($0.agent) }
        
        let activeWorking = combined.filter { $0.workState != .idle }
        let newWorkingAgents = Array(Set(activeWorking.map { $0.agent }))
        
        let targetAgent = activeWorking.first?.agent ?? self.currentAgent
        let targetProject: String
        if let active = activeWorking.first, !active.projectName.isEmpty {
            targetProject = active.projectName
        } else if activeWorking.isEmpty {
            targetProject = ""
        } else {
            targetProject = self.currentProject
        }
        
        let targetWorkState: WorkState
        if activeWorking.contains(where: { $0.workState == .needsConfirmation }) {
            targetWorkState = .needsConfirmation
        } else if activeWorking.contains(where: { $0.workState == .working }) {
            targetWorkState = .working
        } else if activeWorking.contains(where: { $0.workState == .promptReceived }) {
            targetWorkState = .promptReceived
        } else if activeWorking.contains(where: { $0.workState == .done }) {
            targetWorkState = .done
        } else {
            targetWorkState = .idle
        }
        
        // Skip animation and view invalidation if nothing has changed
        if self.instances == combined &&
           self.workingAgents == newWorkingAgents &&
           self.workState == targetWorkState &&
           self.currentAgent == targetAgent &&
           self.currentProject == targetProject {
            return
        }
        
        withAnimation(Self.springAnimation) {
            self.instances = combined
            self.workingAgents = newWorkingAgents
            self.currentAgent = targetAgent
            self.currentProject = targetProject
            
            let previousState = self.workState
            self.workState = targetWorkState
            
            if previousState != self.workState {
                if self.workState == .needsConfirmation, let active = activeWorking.first(where: { $0.workState == .needsConfirmation }) {
                    let isRu = LocalizationService.shared.currentLanguage == .ru
                    let body = tr("Требуется подтверждение для продолжения работы", "Confirmation required to proceed")
                    NotificationService.shared.sendAgentNotification(title: active.agent.displayName, body: body)
                } else if self.workState == .working, let active = activeWorking.first {
                    let isRu = LocalizationService.shared.currentLanguage == .ru
                    let body = tr("Агент начал работу над проектом {0}", "Agent started working on {0}", active.projectName)
                    NotificationService.shared.sendAgentNotification(title: active.agent.displayName, body: body)
                } else if self.workState == .done {
                    let proj = self.currentProject.isEmpty ? "" : " (\(self.currentProject))"
                    let body = tr("Агент завершил задачу{0}", "Agent completed task{0}", proj)
                    NotificationService.shared.sendAgentNotification(title: self.currentAgent.displayName, subtitle: self.currentProject.isEmpty ? "Notchy" : self.currentProject, body: body)
                } else if self.workState == .working || self.workState == .promptReceived {
                    self.doneAutoDismissTimer?.cancel()
                    self.doneAutoDismissTimer = nil
                }
            }
        }
        self.syncStatusToFile()
        self.updateRunningFlag()
    }
    
    private var doneAutoDismissTimer: DispatchWorkItem?
    
    
    public func setWorkState(_ newState: WorkState, agent: AgentType? = nil, project: String? = nil) {
        let targetAgent = agent ?? self.currentAgent
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentAgent = targetAgent
            if let proj = project, !proj.isEmpty, !proj.contains(".gemini"), !proj.contains("brain"), (!proj.contains("-") || proj.count < 30) {
                self.currentProject = proj
            }
            let targetProject = self.currentProject
            let instanceId = "\(targetAgent.rawValue)-\(targetProject)"
            
            // Cancel any pending retraction for this instance
            self.instanceRetractWorkItems[instanceId]?.cancel()
            self.instanceRetractWorkItems[instanceId] = nil
            
            if newState == .idle {
                self.externalInstances.removeAll { $0.agent == targetAgent && ($0.projectName == targetProject || project == nil) }
                if targetAgent == .antigravity {
                    self.antigravityInstances.removeAll { $0.projectName == targetProject || project == nil }
                }
            } else {
                if let idx = self.externalInstances.firstIndex(where: { $0.agent == targetAgent && $0.projectName == targetProject }) {
                    self.externalInstances[idx].workState = newState
                } else {
                    let newInst = AgentInstance(id: instanceId, agent: targetAgent, projectName: targetProject, workState: newState)
                    self.externalInstances.append(newInst)
                }
            }
            
            self.recalculateCombinedInstances()
            
            if newState == .promptReceived {
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    if let idx = self.externalInstances.firstIndex(where: { $0.id == instanceId }),
                       self.externalInstances[idx].workState == .promptReceived {
                        self.externalInstances[idx].workState = .working
                        self.recalculateCombinedInstances()
                    }
                }
                self.instanceRetractWorkItems[instanceId] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
            } else if newState == .done {
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    if let idx = self.externalInstances.firstIndex(where: { $0.id == instanceId }),
                       self.externalInstances[idx].workState == .done {
                        self.externalInstances.remove(at: idx)
                        self.recalculateCombinedInstances()
                    }
                }
                self.instanceRetractWorkItems[instanceId] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 6 * 3600, execute: work)
            }
        }
    }
    
    public func setCurrentAgent(_ agent: AgentType) {
        withAnimation(Self.springAnimation) {
            self.currentAgent = agent
        }
        syncStatusToFile()
    }
    
    public func setCurrentProject(_ project: String) {
        withAnimation(Self.springAnimation) {
            self.currentProject = project
        }
        syncStatusToFile()
    }
    
    public func setInstances(_ list: [AgentInstance]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.externalInstances = list
            self.antigravityInstances = []
            self.recalculateCombinedInstances()
        }
    }
    
    public func setWorkingAgents(_ list: [AgentType]) {
        withAnimation(Self.springAnimation) {
            self.workingAgents = list
            if let first = list.first {
                self.currentAgent = first
            }
            self.workState = list.isEmpty ? .idle : .working
            
            // Generate instances
            self.instances = list.enumerated().map { index, agent in
                let proj = index == 0 ? self.currentProject : "project-\(index + 1)"
                return AgentInstance(id: "\(agent.rawValue)-\(proj)", agent: agent, projectName: proj, workState: .working)
            }
        }
        syncStatusToFile()
    }
    
    // MARK: - Agent Management
    
    public func isAgentActive(_ agent: AgentType) -> Bool {
        activeAgents.contains(agent)
    }
    
    public func setAgent(_ agent: AgentType, active: Bool) {
        withAnimation(Self.springAnimation) {
            if active {
                if !activeAgents.contains(agent) {
                    activeAgents.append(agent)
                    activeAgents.sort { a, b in
                        let order: [AgentType] = [.antigravity, .claude, .codex]
                        let idxA = order.firstIndex(of: a) ?? 0
                        let idxB = order.firstIndex(of: b) ?? 0
                        return idxA < idxB
                    }
                }
            } else {
                activeAgents.removeAll { $0 == agent }
            }
        }
        syncAgentsToFile()
    }
    
    public func toggleAgent(_ agent: AgentType) {
        setAgent(agent, active: !isAgentActive(agent))
    }
    
    public func clearAll() {
        withAnimation(Self.springAnimation) {
            activeAgents.removeAll()
            instances.removeAll()
            workingAgents.removeAll()
            workState = .idle
        }
        syncAgentsToFile()
        syncStatusToFile()
    }
    
    // MARK: - App Lifecycle & Running State
    
    /// Запущено ли GUI-приложение какого-либо агента. CLI-агенты (Claude Code, Codex в терминале)
    /// приложением не являются — о них мы узнаём по событиям хуков, поэтому их сессии здесь не сбрасываются.
    private var agentAppRunning = false
    
    private func updateRunningFlag() {
        let running = agentAppRunning || !instances.isEmpty
        if isAnyAgentAppRunning != running {
            withAnimation(Self.springAnimation) {
                isAnyAgentAppRunning = running
            }
        }
    }
    
    private func setupAppLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appLifecycleChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appLifecycleChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        checkRunningAgentApps()
    }
    
    @objc private func appLifecycleChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.checkRunningAgentApps()
        }
    }
    
    /// Агенты, запущенные в терминале (Claude Code, Codex CLI), — это процессы, а не приложения.
    /// Имя процесса у Claude Code — номер версии, поэтому смотрим путь исполняемого файла (дёшево: один вызов ядра
    /// на процесс, без запуска `ps`).
    private var cliAgents = Set<AgentType>()
    /// Open terminal sessions of CLI agents, one per project folder.
    @Published public private(set) var cliSessions: [AgentInstance] = []
    private var appIdentityCache: [pid_t: (bundleId: String?, name: String?)] = [:]
    
    /// `claude daemon run` (started by Claude Code itself, from the home folder) and its `bg-*` helper processes.
    private static func isBackgroundWorker(pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return false }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return false }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // executable path
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while i < size && args.count < argc {
            var j = i
            while j < size && buf[j] != 0 { j += 1 }
            args.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args.contains { $0 == "daemon" || $0.hasPrefix("bg-") || $0.hasPrefix("--bg-") }
    }
    
    private func refreshCLIAgents() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let count = proc_listallpids(nil, 0)
            guard count > 0 else { return }
            var pids = [pid_t](repeating: 0, count: Int(count) + 32)
            let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            var found = Set<AgentType>()
            var sessions: [AgentInstance] = []
            var buffer = [CChar](repeating: 0, count: 1024)
            for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 {
                guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
                let path = String(cString: buffer)
                let name = (path as NSString).lastPathComponent
                let agent: AgentType
                if name == "claude" || path.contains("/claude/versions/") { agent = .claude }
                else if name == "codex" { agent = .codex }
                else { continue }
                // Claude Code's background service and its spare workers are not chats: they must not show up as projects
                if Self.isBackgroundWorker(pid: pid) { continue }
                found.insert(agent)
                // Each terminal session is its own project: the folder the process was started in
                var vnode = proc_vnodepathinfo()
                guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { continue }
                let cwd = withUnsafePointer(to: &vnode.pvi_cdir.vip_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                let project = (cwd as NSString).lastPathComponent
                guard !project.isEmpty, project != "/", !sessions.contains(where: { $0.agent == agent && $0.projectName == project }) else { continue }
                sessions.append(AgentInstance(id: "idle-\(agent.rawValue)-\(project)", agent: agent, projectName: project, workState: .idle))
            }
            sessions.sort { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.cliSessions != sessions { self.cliSessions = sessions }
                guard self.cliAgents != found else { return }
                self.cliAgents = found
                self.checkRunningAgentApps()
            }
        }
    }
    
    /// Приложение (терминал/IDE), в котором запущен CLI-агент: идём от процесса агента вверх по родителям до обычного приложения.
    public func cliHostApp(for agent: AgentType) -> NSRunningApplication? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buffer = [CChar](repeating: 0, count: 1024)
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            let name = (path as NSString).lastPathComponent
            let isClaude = name == "claude" || path.contains("/claude/versions/")
            guard (agent == .claude && isClaude) || (agent == .codex && name == "codex") else { continue }
            var current = pid
            for _ in 0..<12 {
                // sysctl, not proc_pidinfo: `login` runs as root, and its info is closed to us
                var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
                var info = kinfo_proc()
                var size = MemoryLayout<kinfo_proc>.stride
                guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
                let parent = info.kp_eproc.e_ppid
                if parent <= 1 { break }
                if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular { return app }
                current = parent
            }
        }
        return nil
    }
    
    public func checkRunningAgentApps() {
        // Только обычные приложения: системные помощники и XPC-службы (например CursorUIViewService) не в счёт
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        // localizedName is an expensive lookup: read each app's identity once and reuse it on every poll
        var identities: [pid_t: (bundleId: String?, name: String?)] = [:]
        for app in apps {
            identities[app.processIdentifier] = appIdentityCache[app.processIdentifier] ?? (app.bundleIdentifier, app.localizedName)
        }
        appIdentityCache = identities
        let cli = cliAgents
        let open = AgentType.allCases.filter { agent in
            AgentHookManager.shared.isEnabled(agent)
                && (cli.contains(agent) || identities.values.contains { agent.matches(bundleId: $0.bundleId, name: $0.name) })
        }
        if runningAgents != open { runningAgents = open }
        agentAppRunning = !open.isEmpty
        updateRunningFlag()
        
        // Закрылось приложение Antigravity — его сессии из транскриптов больше не актуальны
        let hasAntigravity = identities.values.contains { AgentType.antigravity.matches(bundleId: $0.bundleId, name: $0.name) }
        if !hasAntigravity, !antigravityInstances.isEmpty {
            antigravityInstances.removeAll()
            TranscriptWatcher.shared.clearAll()
            recalculateCombinedInstances()
        }
    }
    
    // MARK: - 3-Second Agents Tab Viewing Timer
    
    public func startViewingAgentsTab() {
        cancelViewingAgentsTab()
        guard instances.contains(where: { $0.workState == .done }) else { return }
        
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.markDoneInstancesAsSeen()
            self.dismissSeenDoneInstances()
        }
        self.agentsTabDwellTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
    }
    
    public func cancelViewingAgentsTab() {
        agentsTabDwellTimer?.cancel()
        agentsTabDwellTimer = nil
    }
    
    public func markDoneInstancesAsSeen() {
        for i in 0..<instances.count {
            if instances[i].workState == .done {
                instances[i].hasBeenSeen = true
            }
        }
        for i in 0..<antigravityInstances.count {
            if antigravityInstances[i].workState == .done {
                antigravityInstances[i].hasBeenSeen = true
            }
        }
        for i in 0..<externalInstances.count {
            if externalInstances[i].workState == .done {
                externalInstances[i].hasBeenSeen = true
            }
        }
        for i in 0..<hookInstances.count {
            if hookInstances[i].workState == .done {
                hookInstances[i].hasBeenSeen = true
            }
        }
    }
    
    public func dismissSeenDoneInstances() {
        withAnimation(Self.springAnimation) {
            let beforeCount = self.instances.count
            self.instances.removeAll { $0.workState == .done && $0.hasBeenSeen }
            self.antigravityInstances.removeAll { $0.workState == .done && $0.hasBeenSeen }
            self.externalInstances.removeAll { $0.workState == .done && $0.hasBeenSeen }
            self.hookInstances.removeAll { $0.workState == .done && $0.hasBeenSeen }
            TranscriptWatcher.shared.dismissAllDoneSessions()
            AgentEventsWatcher.shared.dismissAllDoneSessions()
            if self.instances.count != beforeCount {
                self.recalculateCombinedInstances()
            }
        }
    }
    
    public func dismissInstance(id: String) {
        withAnimation(Self.springAnimation) {
            self.instances.removeAll { $0.id == id }
            self.antigravityInstances.removeAll { $0.id == id }
            self.externalInstances.removeAll { $0.id == id }
            self.hookInstances.removeAll { $0.id == id }
            TranscriptWatcher.shared.dismissAllDoneSessions()
            AgentEventsWatcher.shared.dismissSession(id: id)
            self.recalculateCombinedInstances()
        }
    }
    
    // MARK: - Polling
    
    private func startPolling() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: statusFilePath),
           let modDate = attrs[.modificationDate] as? Date {
            self.lastStatusModDate = modDate
        } else {
            self.lastStatusModDate = Date()
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: agentsFilePath),
           let modDate = attrs[.modificationDate] as? Date {
            self.lastAgentsModDate = modDate
        } else {
            self.lastAgentsModDate = Date()
        }
        pollTimer?.invalidate()
        // Внешние управляющие файлы (scripts/) проверяем редко: stat двух файлов раз в 2.5 с
        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.checkFiles()
            self?.refreshCLIAgents() // CLI-агенты запускаются без уведомления системы
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
    
    // MARK: - File Sync
    
    private func syncAgentsToFile() {
        let rawValues = activeAgents.map { $0.rawValue }
        if let data = try? JSONSerialization.data(withJSONObject: rawValues, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: agentsFilePath), options: .atomic)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: agentsFilePath),
               let modDate = attrs[.modificationDate] as? Date {
                self.lastAgentsModDate = modDate
            }
        }
    }
    
    private func syncStatusToFile() {
        let instancesData = instances.map { inst in
            [
                "id": inst.id,
                "agent": inst.agent.rawValue,
                "project": inst.projectName,
                "state": inst.workState.rawValue
            ]
        }
        let dict: [String: Any] = [
            "source": "Notchy",
            "state": workState.rawValue,
            "agent": currentAgent.rawValue,
            "project": currentProject,
            "working_agents": workingAgents.map { $0.rawValue },
            "instances": instancesData
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: statusFilePath), options: .atomic)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: statusFilePath),
               let modDate = attrs[.modificationDate] as? Date {
                self.lastStatusModDate = modDate
            }
        }
    }
    
    private func checkFiles() {
        // Check /tmp/notchy_status.json
        if FileManager.default.fileExists(atPath: statusFilePath),
           let attrs = try? FileManager.default.attributesOfItem(atPath: statusFilePath),
           let modDate = attrs[.modificationDate] as? Date {
            
            if lastStatusModDate == nil || modDate > lastStatusModDate! {
                lastStatusModDate = modDate
                if let data = try? Data(contentsOf: URL(fileURLWithPath: statusFilePath)),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    
                    // CRITICAL: Ignore updates written by Notchy itself to prevent feedback loop and state flickering
                    if let src = dict["source"] as? String, src == "Notchy" {
                        return
                    }
                    
                    if let tabStr = dict["tab"] as? String {
                        DispatchQueue.main.async {
                            self.requestedTab = tabStr.lowercased()
                        }
                    }
                   
                    // 1. Check for detailed instances array: [{"agent": "antigravity", "project": "notch", "state": "working"}, ...]
                    if let rawInstances = dict["instances"] as? [[String: Any]] {
                        if rawInstances.isEmpty {
                            DispatchQueue.main.async {
                                self.setExternalInstances([])
                            }
                            return
                        }
                        var parsedInstances: [AgentInstance] = []
                        for item in rawInstances {
                            guard let agentStr = (item["agent"] as? String) ?? (item["type"] as? String),
                                  let agent = AgentType(rawValue: agentStr.lowercased()) else { continue }
                            let proj = (item["project"] as? String) ?? (item["projectName"] as? String) ?? (item["name"] as? String) ?? ""
                            let stateStr = (item["state"] as? String) ?? (item["work_state"] as? String) ?? "working"
                            let st: WorkState
                            switch stateStr.lowercased() {
                            case "prompt", "prompt_received": st = .promptReceived
                            case "working", "work": st = .working
                            case "done", "complete": st = .done
                            case "needs_confirmation", "confirmation", "confirm", "waiting_for_input", "approval": st = .needsConfirmation
                            default: st = .idle
                            }
                            let id = (item["id"] as? String) ?? "\(agent.rawValue)-\(proj)-\(UUID().uuidString.prefix(4))"
                            parsedInstances.append(AgentInstance(id: id, agent: agent, projectName: proj, workState: st))
                        }
                        DispatchQueue.main.async {
                            self.setExternalInstances(parsedInstances)
                        }
                        return
                    }
                    
                    // 2. Check for working_agents array (could be strings e.g. "antigravity:notch" or objects)
                    if let workingList = (dict["working_agents"] as? [Any]) ?? (dict["agents"] as? [Any]) {
                        var parsedInstances: [AgentInstance] = []
                        for item in workingList {
                            if let str = item as? String {
                                let parts = str.components(separatedBy: ":")
                                if let agent = AgentType(rawValue: parts[0].lowercased()) {
                                    let proj = parts.count > 1 ? parts[1] : self.currentProject
                                    parsedInstances.append(AgentInstance(id: "\(agent.rawValue)-\(proj)", agent: agent, projectName: proj, workState: .working))
                                }
                            } else if let dictItem = item as? [String: Any] {
                                if let agentStr = dictItem["agent"] as? String,
                                   let agent = AgentType(rawValue: agentStr.lowercased()) {
                                    let proj = (dictItem["project"] as? String) ?? self.currentProject
                                    parsedInstances.append(AgentInstance(id: "\(agent.rawValue)-\(proj)", agent: agent, projectName: proj, workState: .working))
                                }
                            }
                        }
                        if !parsedInstances.isEmpty {
                            DispatchQueue.main.async {
                                self.setExternalInstances(parsedInstances)
                            }
                            return
                        }
                    }
                   
                    // 3. Simple single state format
                    let projectStr = (dict["project"] as? String) ?? (dict["workspace"] as? String)
                    if let proj = projectStr {
                        DispatchQueue.main.async {
                            self.currentProject = proj
                        }
                    }
                    
                    if let stateStr = (dict["state"] as? String) ?? (dict["work_state"] as? String) {
                        let parsedAgent = (dict["agent"] as? String).flatMap { AgentType(rawValue: $0.lowercased()) } ?? self.currentAgent
                        
                        let parsedState: WorkState
                        switch stateStr.lowercased() {
                        case "prompt", "prompt_received", "promptreceived":
                            parsedState = .promptReceived
                        case "working", "work", "busy":
                            parsedState = .working
                        case "done", "complete", "completed":
                            parsedState = .done
                        case "needs_confirmation", "confirmation", "confirm", "waiting_for_input", "approval":
                            parsedState = .needsConfirmation
                        default:
                            parsedState = .idle
                        }
                        
                        self.setWorkState(parsedState, agent: parsedAgent, project: projectStr)
                    }
                }
            }
        }
        
        // Check /tmp/notchy_agents.json
        if FileManager.default.fileExists(atPath: agentsFilePath),
           let attrs = try? FileManager.default.attributesOfItem(atPath: agentsFilePath),
           let modDate = attrs[.modificationDate] as? Date {
            
            if lastAgentsModDate == nil || modDate > lastAgentsModDate! {
                lastAgentsModDate = modDate
                if let data = try? Data(contentsOf: URL(fileURLWithPath: agentsFilePath)),
                   let list = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    let parsedAgents = list.compactMap { AgentType(rawValue: $0.lowercased()) }
                    DispatchQueue.main.async {
                        if self.activeAgents != parsedAgents {
                            withAnimation(Self.springAnimation) {
                                self.activeAgents = parsedAgents
                            }
                        }
                    }
                }
            }
        }
    }
}

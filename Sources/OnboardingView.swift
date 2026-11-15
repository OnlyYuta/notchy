import SwiftUI
import AppKit
import ApplicationServices

/// First-run guide in three steps: what the app does, the macOS permissions it needs and why, and how to use it.
public struct OnboardingView: View {
    @ObservedObject private var l10n = LocalizationService.shared
    @ObservedObject private var permissions = PermissionManager.shared

    public var onComplete: () -> Void

    @State private var step = 0
    @State private var goingForward = true
    /// Permission currently being requested by "Allow all" (highlighted)
    @State private var requesting: Permission?
    @State private var requestingAll = false
    @AppStorage("onboarding_automation_done") private var automationDone = false
    @AppStorage("onboarding_automation_note") private var automationNote = ""
    @AppStorage("onboarding_folders_done") private var foldersDone = false
    @AppStorage("onboarding_screen_requested") private var screenRequested = false

    private static let steps = 3

    public init(onComplete: @escaping () -> Void = {}) {
        self.onComplete = onComplete
    }


    public var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow).ignoresSafeArea()
            Color.black.opacity(0.35).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ZStack {
                    switch step {
                    case 0: welcomeStep.transition(pageTransition)
                    case 1: permissionsStep.transition(pageTransition)
                    default: readyStep.transition(pageTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                footer
            }
        }
        .frame(minWidth: 580, minHeight: 720)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: goingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: goingForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    // MARK: - Header & footer

    private var header: some View {
        HStack {
            // Step dots
            HStack(spacing: 6) {
                ForEach(0..<Self.steps, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.white : Color.white.opacity(0.22))
                        .frame(width: i == step ? 20 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)

            Spacer()

            // Language: a menu, since there are nine of them
            Menu {
                ForEach(AppLanguage.allCases) { lang in
                    Button(action: {
                        l10n.setLanguage(lang)
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                    }) {
                        Text(l10n.currentLanguage == lang ? "✓ \(lang.displayName)" : lang.displayName)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "globe").font(.system(size: 10.5, weight: .semibold))
                    Text(l10n.currentLanguage.displayName)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Divider().background(Color.white.opacity(0.12))
            HStack(spacing: 10) {
                if step > 0 {
                    Button(action: { go(step - 1) }) {
                        Text(tr("Назад", "Back"))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    if step < Self.steps - 1 {
                        go(step + 1)
                    } else {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                        onComplete()
                    }
                }) {
                    HStack(spacing: 7) {
                        Text(step == 0 ? tr("Далее: разрешения", "Next: permissions")
                             : step == 1 ? tr("Далее", "Next")
                             : tr("Начать использование", "Get started"))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Image(systemName: step == Self.steps - 1 ? "checkmark" : "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private func go(_ target: Int) {
        goingForward = target > step
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = target }
    }

    // MARK: - Step 1: what it does

    private var welcomeStep: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    appIcon
                    Text(tr("Добро пожаловать в Notchy", "Welcome to Notchy"))
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    Text(tr("Челка вашего MacBook становится панелью: наведите на неё курсор, и она раскроется.",
                            "Your MacBook's notch becomes a panel: hover over it and it opens."))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.top, 4)

                VStack(spacing: 8) {
                    featureRow(icon: "sparkles", color: Color(red: 1.0, green: 0.65, blue: 0.0),
                               title: tr("ИИ-агенты", "AI agents"),
                               desc: tr("Показывает, когда Claude, Codex и Antigravity работают, ждут вашего подтверждения или закончили. Список сессий в раскрытой челке.",
                                        "Shows when Claude, Codex and Antigravity are working, waiting for your approval or done. A session list in the open notch."))
                    featureRow(icon: "music.note", color: Color(red: 0.0, green: 0.85, blue: 0.95),
                               title: tr("Музыка", "Music"),
                               desc: tr("Обложка, ход трека и кнопки управления. Челка сама показывает смену трека.",
                                        "Cover, progress and controls. The notch announces track changes by itself."))
                    featureRow(icon: "record.circle", color: Color(red: 1.0, green: 0.3, blue: 0.3),
                               title: tr("Запись экрана и мгновенный повтор", "Screen recording and instant replay"),
                               desc: tr("Запишите экран или сохраните последние минуты по горячей клавише, как в играх. Работает в фоне с минимальной нагрузкой.",
                                        "Record the screen or save the last minutes with a hotkey, like in games. Runs in the background with minimal load."))
                    featureRow(icon: "doc.on.clipboard", color: Color(red: 0.35, green: 0.6, blue: 1.0),
                               title: tr("Буфер обмена и конвертер", "Clipboard and converter"),
                               desc: tr("История копирования. Перетащите файл в челку, чтобы сохранить его, или на формат вокруг челки, чтобы конвертировать в «Загрузки».",
                                        "Copy history. Drag a file into the notch to keep it, or onto a format around the notch to convert it into Downloads."))
                    featureRow(icon: "cup.and.saucer.fill", color: Color(red: 1.0, green: 0.58, blue: 0.12),
                               title: tr("Не спать", "Keep awake"),
                               desc: tr("Mac не заснёт на выбранное время, чтобы агенты и загрузки не прерывались. Можно даже с закрытой крышкой.",
                                        "The Mac stays awake for as long as you choose so agents and downloads aren't interrupted. Even with the lid closed."))
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 16)
        }
    }

    private func featureRow(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(desc)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    // MARK: - Step 2: permissions

    private enum Permission: CaseIterable, Identifiable {
        case accessibility, screen, notifications, automation, folders, microphone
        var id: Self { self }
    }

    private func isGranted(_ p: Permission) -> Bool {
        switch p {
        case .accessibility: return permissions.isAccessibilityGranted
        case .screen: return permissions.isScreenCaptureGranted
        case .notifications: return permissions.isNotificationsGranted
        case .microphone: return permissions.isMicrophoneGranted
        case .automation: return automationDone
        case .folders: return foldersDone
        }
    }

    private var missing: [Permission] { Permission.allCases.filter { !isGranted($0) } }

    private var permissionsStep: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                VStack(spacing: 5) {
                    Text(tr("Разрешения macOS", "macOS permissions"))
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(tr("Каждый пункт открывает отдельную функцию. Запись, звук, буфер и файлы остаются на вашем Mac. Ничего из этого не обязательно давать сразу: можно вернуться позже.",
                            "Each item unlocks a feature. Recordings, audio, clipboard and files stay on your Mac. You don't have to grant everything now: you can come back later."))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .padding(.top, 2)

                if !permissions.isInstalledInApplications {
                    HStack(spacing: 8) {
                        Image(systemName: "lightbulb.fill").foregroundColor(.orange).font(.system(size: 12))
                        Text(tr("Скопируйте Notchy в «Программы»: иначе macOS может сбрасывать разрешения при обновлении.",
                                "Copy Notchy to Applications: otherwise macOS may reset permissions on updates."))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
                }

                // One button that walks through everything still missing
                Button(action: requestAll) {
                    HStack(spacing: 8) {
                        if requestingAll { ProgressView().controlSize(.small).colorScheme(.dark) }
                        else { Image(systemName: missing.isEmpty ? "checkmark.seal.fill" : "wand.and.stars") }
                        Text(missing.isEmpty ? tr("Всё разрешено", "Everything allowed")
                             : requestingAll ? tr("Идёт запрос: следуйте подсказкам macOS…", "Requesting: follow the macOS prompts…")
                             : tr("Разрешить всё по очереди", "Allow everything, one by one"))
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(missing.isEmpty ? Color.green.opacity(0.35) : Color.blue))
                }
                .buttonStyle(.plain)
                .disabled(missing.isEmpty || requestingAll)

                VStack(spacing: 8) {
                    ForEach(Permission.allCases) { permissionRow($0) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
        }
    }

    private func details(_ p: Permission) -> (icon: String, color: Color, title: String, tag: String, why: String) {
        switch p {
        case .accessibility:
            return ("accessibility", .blue, tr("Универсальный доступ", "Accessibility"), tr("Обязательно", "Required"),
                    tr("Чтобы открывать значки строки меню из челки, нажимать кнопки плееров (AuMusic и др.), читать трек и ловить горячие клавиши записи.",
                       "To open menu bar icons from the notch, press player buttons (AuMusic and others), read the current track and catch the recording hotkeys."))
        case .screen:
            return ("record.circle", .red, tr("Запись экрана и системного звука", "Screen & system audio recording"), tr("Для записи", "For recording"),
                    tr("Нужно для записи экрана и мгновенного повтора, а ещё чтобы определять, что играет в браузере. После выдачи может понадобиться перезапуск.",
                       "Needed for screen recording and instant replay, and to detect what is playing in the browser. A relaunch may be needed after granting."))
        case .notifications:
            return ("bell.badge.fill", .pink, tr("Уведомления", "Notifications"), tr("Рекомендуется", "Recommended"),
                    tr("Чтобы сообщить, что агент закончил задачу, сменился трек или сохранился повтор, пока вы смотрите в другое окно.",
                       "To tell you an agent finished, the track changed or a replay was saved while you're looking at another window."))
        case .automation:
            return ("play.circle.fill", .green, tr("Управление Music и Spotify", "Control Music and Spotify"), tr("Рекомендуется", "Recommended"),
                    tr("Чтобы кнопки пауза, вперёд и назад в челке управляли Music и Spotify. Откройте нужный плеер перед запросом.",
                       "So the pause, next and previous buttons in the notch control Music and Spotify. Open the player before requesting."))
        case .folders:
            return ("folder.fill", .cyan, tr("Папки: Загрузки, Рабочий стол, Документы", "Folders: Downloads, Desktop, Documents"), tr("Рекомендуется", "Recommended"),
                    tr("Чтобы сохранять записи, повторы и конвертированные файлы туда, куда вы укажете, и без лишних запросов потом.",
                       "To save recordings, replays and converted files where you choose, without more prompts later."))
        case .microphone:
            return ("mic.fill", .orange, tr("Микрофон", "Microphone"), tr("По желанию", "Optional"),
                    tr("Только если хотите записывать свой голос вместе с экраном. Без него запись идёт со звуком системы.",
                       "Only if you want your voice recorded with the screen. Without it recordings carry system sound."))
        }
    }

    private func permissionRow(_ p: Permission) -> some View {
        let info = details(p)
        let granted = isGranted(p)
        let active = requesting == p
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: info.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(info.color)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(info.color.opacity(0.16)))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(info.title)
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text(info.tag)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(p == .accessibility ? .orange : .white.opacity(0.6))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(p == .accessibility ? Color.orange.opacity(0.18) : Color.white.opacity(0.1)))
                    }
                    Text(info.why)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    if p == .automation && !automationNote.isEmpty && !granted {
                        Text(automationNote)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.yellow)
                    }
                }
                Spacer(minLength: 4)

                if granted {
                    Label(tr("Разрешено", "Allowed"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                } else {
                    Button(action: { request(p) }) {
                        Text(tr("Разрешить", "Allow"))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.blue))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Screen recording usually only takes effect after a relaunch
            if p == .screen && screenRequested && !granted {
                HStack(spacing: 8) {
                    Text(tr("Включили переключатель? Перезапустите приложение, чтобы доступ заработал.", "Switched it on? Relaunch the app so the access takes effect."))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Button(action: { permissions.restartApplication() }) {
                        Text(tr("Перезапустить", "Relaunch"))
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.green))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(active ? 0.1 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(active ? Color.blue.opacity(0.7) : Color.clear, lineWidth: 1.2))
        .animation(.easeOut(duration: 0.2), value: active)
    }

    // MARK: Requests

    private func request(_ p: Permission) {
        switch p {
        case .accessibility: permissions.requestAccessibility()
        case .screen:
            screenRequested = true
            permissions.requestScreenCapture()
        case .notifications: permissions.requestNotifications()
        case .microphone: permissions.requestMicrophone()
        case .automation: requestAutomation()
        case .folders: requestFolders()
        }
    }

    /// Asks every missing permission in turn and waits (up to ~40 s each) for the answer before moving on.
    private func requestAll() {
        guard !requestingAll else { return }
        requestingAll = true
        let queue = missing
        Task { @MainActor in
            for p in queue where !isGranted(p) {
                requesting = p
                request(p)
                for _ in 0..<80 {          // 80 x 0.5 s
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if isGranted(p) { break }
                }
            }
            requesting = nil
            requestingAll = false
        }
    }

    /// Apple Events permission is per target app; the system asks when the request is made for a running app.
    private func requestAutomation() {
        var running = 0, allowed = 0
        for bundleId in ["com.apple.Music", "com.spotify.client"] where !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
            running += 1
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
            if let desc = target.aeDesc, AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), true) == noErr {
                allowed += 1
            }
        }
        if allowed > 0 {
            automationDone = true
            automationNote = ""
        } else if running == 0 {
            automationNote = tr("Music и Spotify не запущены: откройте плеер и нажмите ещё раз", "Music and Spotify aren't running: open a player and press again")
        } else {
            automationNote = tr("Доступ не выдан: включите Notchy в «Конфиденциальность → Автоматизация»", "Not allowed: enable Notchy in Privacy → Automation")
        }
    }

    /// Reading each folder once makes macOS show its access prompt now instead of at the first save.
    private func requestFolders() {
        let fm = FileManager.default
        let dirs: [FileManager.SearchPathDirectory] = [.downloadsDirectory, .desktopDirectory, .documentDirectory]
        var allOk = true
        for dir in dirs {
            guard let url = fm.urls(for: dir, in: .userDomainMask).first else { continue }
            if (try? fm.contentsOfDirectory(atPath: url.path)) == nil { allOk = false }
        }
        foldersDone = allOk
    }

    // MARK: - Step 3: ready

    private var readyStep: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 46))
                        .foregroundColor(.green)
                        .padding(.top, 10)
                    Text(tr("Всё готово", "You're all set"))
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(missing.isEmpty ? tr("Все разрешения выданы.", "All permissions are granted.")
                         : tr("Не выдано: {0}. Это можно сделать позже: «Настройки» → «Окно приветствия».",
                              "Not granted: {0}. You can do it later: Settings → Welcome window.", missing.count))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }

                if !permissions.isAccessibilityGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(tr("Без универсального доступа не будут работать значки меню и кнопки сторонних плееров.",
                                "Without Accessibility, menu bar icons and third-party player buttons won't work."))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
                }

                VStack(spacing: 8) {
                    tipRow(icon: "cursorarrow.motionlines", title: tr("Как открыть", "How to open"),
                           desc: tr("Наведите курсор на челку вверху экрана: она раскроется. Уведите курсор: свернётся.", "Hover over the notch at the top of the screen: it opens. Move away: it closes."))
                    tipRow(icon: "hand.draw", title: tr("Вкладки", "Tabs"),
                           desc: tr("Листайте вкладки свайпом двумя пальцами по тачпаду или нажимайте на значки вверху.", "Switch tabs with a two-finger swipe on the trackpad or by clicking the icons at the top."))
                    tipRow(icon: "tray.and.arrow.down", title: tr("Файлы", "Files"),
                           desc: tr("Перетащите файл к челке: в центр, чтобы сохранить в буфер, или на формат вокруг, чтобы конвертировать в «Загрузки».", "Drag a file to the notch: into the middle to save it to the clipboard, or onto a format around it to convert it into Downloads."))
                    tipRow(icon: "keyboard", title: tr("Запись по клавишам", "Recording hotkeys"),
                           desc: tr("⌥⇧R запускает запись, ⌥⇧S сохраняет мгновенный повтор. Клавиши меняются в «Настройках».", "⌥⇧R starts recording, ⌥⇧S saves the instant replay. Change the keys in Settings."))
                    tipRow(icon: "gearshape.fill", title: tr("Настройки", "Settings"),
                           desc: tr("Значок-ползунки на вкладке «Настройки» или значок Notchy в строке меню открывают все параметры.", "The sliders button on the Settings tab or the Notchy menu bar icon opens all options."))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private func tipRow(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(.white)
                Text(desc).font(.system(size: 11, weight: .regular, design: .rounded)).foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    // MARK: - Pieces

    private var appIcon: some View {
        Group {
            if let iconImage = loadAppIconImage() {
                Image(nsImage: iconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 76, height: 76)
                    Image(systemName: "capsule.portrait.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [.cyan, .purple, .orange], startPoint: .leading, endPoint: .trailing))
                }
            }
        }
        .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 5)
    }

    private func loadAppIconImage() -> NSImage? {
        if let bundleImage = Bundle.main.image(forResource: "AppIcon") {
            return bundleImage
        }
        let bundleRes = Bundle.main.bundlePath + "/Contents/Resources/AppIcon.png"
        if let img = NSImage(contentsOfFile: bundleRes) {
            return img
        }
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "png"),
           let img = NSImage(contentsOfFile: iconPath) {
            return img
        }
        return nil
    }
}

// NSVisualEffectView helper
public struct VisualEffectView: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode

    public init(material: NSVisualEffectView.Material, blendingMode: NSVisualEffectView.BlendingMode) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

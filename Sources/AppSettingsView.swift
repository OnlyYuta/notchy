import SwiftUI
import AppKit
import ServiceManagement

/// Full settings, in their own window. Ordered by how often they matter: agents and keep-awake first, then notifications and
/// recording, then what the notch shows, and rarely touched things (language, welcome guide) at the bottom.
public struct AppSettingsView: View {
    @ObservedObject private var l10n = LocalizationService.shared
    @ObservedObject private var settings = SettingsService.shared
    @AppStorage("show_menu_bar_icon") private var showMenuBarIcon = true
    @ObservedObject private var recSettings = ScreenRecorderSettings.shared
    @ObservedObject private var connections = AgentConnections.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    public init() {}


    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                agentsSection
                keepAwakeSection
                notificationsSection
                recordingSection
                tabsSection
                displaysSection
                moreSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Sections

    /// Which AI agents the notch follows
    private var agentsSection: some View {
        section(title: tr("Агенты", "Agents"),
                footer: tr("Включённый агент показывается в челке, пока работает. Подключение добавляет в его конфиг маленький хук; выключение его убирает.",
                           "A switched-on agent is shown in the notch while it works. Connecting adds a small hook to its config; switching off removes it.")) {
            ForEach(Array(HookAgent.allCases.enumerated()), id: \.element.id) { index, agent in
                if index > 0 { divider }
                agentRow(agent)
            }
        }
    }

    private func agentRow(_ agent: HookAgent) -> some View {
        let state = connections.state(agent)
        let on = state == .connected || state == .failed
        return HStack(spacing: 12) {
            AgentBadgeView(agent: agent.agentType, size: 18, isBreathing: false)
                .frame(width: 30, height: 30)
                .opacity(state == .notDetected ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.agentType.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                HStack(spacing: 5) {
                    Circle().fill(state.color).frame(width: 6, height: 6)
                    Text(state.label)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { _ in connections.toggle(agent) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(state == .notDetected)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .onAppear { connections.refresh() }
    }

    /// Keep awake, with how long and the lid option in the same card
    private var keepAwakeSection: some View {
        section(title: tr("Не усыплять Mac", "Keep awake"),
                footer: tr("Пока включено, Mac не засыпает: агенты, загрузки и сборки не прерываются.",
                           "While on, the Mac doesn't sleep, so agents, downloads and builds aren't interrupted.")) {
            row(icon: "cup.and.saucer.fill", tint: .orange,
                title: tr("Не усыплять", "Keep awake"),
                subtitle: keepAwakeStatus) {
                Toggle("", isOn: Binding(
                    get: { settings.preventSleepEnabled },
                    set: { new in withAnimation(NotchViewModel.springAnimation) { settings.preventSleepEnabled = new } }
                ))
                .toggleStyle(.switch).labelsHidden()
            }
            divider
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("На какое время", "For how long"))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                HStack(spacing: 4) {
                    ForEach(KeepAwakeDuration.allCases) { duration in
                        let selected = settings.keepAwakeDuration == duration
                        Button(action: { settings.keepAwakeDuration = duration }) {
                            Text(duration.title)
                                .font(.system(size: 11, weight: selected ? .bold : .medium, design: .rounded))
                                .foregroundColor(selected ? .black : .white.opacity(0.78))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.orange : Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            divider
            row(icon: "laptopcomputer", tint: .gray,
                title: tr("И с закрытой крышкой", "Even with the lid closed"),
                subtitle: tr("Нужен пароль администратора. Mac не уснёт при закрытии крышки: следите за нагревом.",
                             "Needs the administrator password. The Mac won't sleep when the lid closes: watch the heat.")) {
                Toggle("", isOn: $settings.keepAwakeClosedLid).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private var keepAwakeStatus: String {
        guard settings.preventSleepEnabled else { return tr("Выключено", "Off") }
        guard settings.keepAwakeEndsAt != nil else { return tr("Включено без ограничения", "On, no limit") }
        return tr("Включено", "On")
    }

    private var notificationsSection: some View {
        section(title: tr("Уведомления", "Notifications")) {
            row(icon: "sparkles", tint: .yellow,
                title: l10n.t(.settingsAgentNotifications),
                subtitle: l10n.t(.settingsAgentNotificationsDesc)) {
                Toggle("", isOn: $settings.agentNotificationsEnabled).toggleStyle(.switch).labelsHidden()
            }
            divider
            row(icon: "speaker.wave.2.fill", tint: .orange,
                title: tr("Звук по завершении", "Sound when done"),
                subtitle: tr("Короткий сигнал, когда агент закончил работу", "A short chime when an agent finishes")) {
                Toggle("", isOn: $settings.agentDoneSoundEnabled).toggleStyle(.switch).labelsHidden()
            }
            divider
            row(icon: "music.note", tint: .green,
                title: l10n.t(.settingsMusicNotifications),
                subtitle: l10n.t(.settingsMusicNotificationsDesc)) {
                Toggle("", isOn: $settings.musicNotificationsEnabled).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private var recordingSection: some View {
        section(title: tr("Запись экрана и повтор", "Screen recording and replay")) {
            VStack(spacing: 0) {
                ShortcutRecorderView(title: l10n.t(.settingsHotkeyReplay), combo: $recSettings.hotkeyReplay)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                divider
                ShortcutRecorderView(title: l10n.t(.settingsHotkeyRecord), combo: $recSettings.hotkeyRecord)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
            divider
            row(icon: "folder.fill", tint: .cyan, title: l10n.t(.settingsSaveFolder),
                subtitle: recSettings.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                HStack(spacing: 6) {
                    pillButton(tr("Выбрать…", "Choose…")) { chooseSaveFolder() }
                    Button(action: { NSWorkspace.shared.activateFileViewerSelecting([recSettings.saveFolder]) }) {
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .help(tr("Показать в Finder", "Reveal in Finder"))
                }
            }
            divider
            row(icon: "aspectratio.fill", tint: .purple, title: tr("Разрешение", "Resolution"), subtitle: nil) {
                Picker("", selection: $recSettings.resolution) {
                    ForEach(VideoResolution.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
            divider
            row(icon: "speedometer", tint: .pink, title: tr("Частота кадров", "Frame rate"),
                subtitle: tr("Повтор пишется не выше 16 Mbps и 1080p", "Replay is capped at 16 Mbps and 1080p")) {
                Picker("", selection: $recSettings.fps) {
                    ForEach(VideoFPS.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
            divider
            row(icon: "dial.medium.fill", tint: .green, title: tr("Битрейт", "Bitrate"), subtitle: nil) {
                Picker("", selection: $recSettings.bitrate) {
                    ForEach(VideoBitrate.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
            divider
            row(icon: "mic.fill", tint: .orange, title: l10n.t(.recordMicDeviceTitle), subtitle: recSettings.currentMicrophoneName) {
                Menu {
                    ForEach(recSettings.availableMicrophones) { dev in
                        Button(action: { recSettings.selectedMicrophoneID = dev.id }) {
                            let selected = (recSettings.selectedMicrophoneID.isEmpty && dev.id.isEmpty) || recSettings.selectedMicrophoneID == dev.id
                            Text(selected ? "✓ \(dev.name)" : dev.name)
                        }
                    }
                } label: {
                    Text(tr("Изменить", "Change"))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            divider
            row(icon: "eye.slash.fill", tint: .teal, title: l10n.t(.recordHideNotchTitle), subtitle: l10n.t(.recordHideNotchDesc)) {
                Toggle("", isOn: $recSettings.hideNotchOnRecording).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private var tabsSection: some View {
        section(title: tr("Вкладки в челке", "Notch tabs"), footer: l10n.t(.settingsTabsSectionDesc)) {
            ForEach(Array([ExpandedTab.agents, .music, .record, .clipboard].enumerated()), id: \.element.id) { index, tab in
                if index > 0 { divider }
                let visible = settings.isTabVisible(tab)
                let isOnlyOne = settings.visibleTabs.count <= 1 && visible
                row(icon: tab.icon, tint: .gray, title: tab.title, subtitle: nil) {
                    Toggle("", isOn: Binding(get: { visible }, set: { _ in if !isOnlyOne { settings.toggleTabVisibility(tab) } }))
                        .toggleStyle(.switch).labelsHidden().disabled(isOnlyOne)
                }
            }
            divider
            row(icon: "computermouse.fill", tint: .indigo,
                title: tr("Боковые кнопки мыши", "Mouse side buttons"),
                subtitle: tr("«Назад» — следующая вкладка, «Вперёд» — предыдущая", "Back goes to the next tab, Forward to the previous one")) {
                Toggle("", isOn: $settings.mouseSideButtonsTabs).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private var displaysSection: some View {
        section(title: tr("Монитор", "Display"), footer: tr("Челка остаётся на выбранном мониторе, даже если курсор уходит на другой. «Всех мониторах» — своя челка на каждом.", "The notch stays on the chosen display even when the cursor moves to another one. \"All displays\" gives each one its own notch.")) {
            row(icon: "display", tint: .gray, title: tr("Показывать челку на", "Show the notch on"), subtitle: nil) {
                Picker("", selection: $settings.notchDisplayID) {
                    Text(tr("Встроенном (авто)", "Built-in (auto)")).tag("auto")
                    Text(tr("Всех мониторах", "All displays")).tag("all")
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        if let id = NotchManager.displayID(of: screen) {
                            Text(screen.localizedName).tag(String(id))
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            divider
            row(icon: "eye.slash.fill", tint: .gray,
                title: tr("Скрывать на внешних мониторах", "Hide on external displays"),
                subtitle: tr("У внешних мониторов нет выреза под камеру", "External displays have no camera cutout")) {
                Toggle("", isOn: $settings.disableOnExternalDisplays).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    /// Rarely touched: language and the welcome guide
    private var moreSection: some View {
        section(title: tr("Дополнительно", "More")) {
            row(icon: "power", tint: .green,
                title: tr("Запускать при входе", "Open at login"),
                subtitle: tr("Челка появляется сразу после входа в систему", "The notch appears right after you log in")) {
                Toggle("", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("⚠️ Notchy: open at login: %@", error.localizedDescription)
                        }
                        // The system has the last word (it may refuse, or need approval in Login Items)
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                ))
                .toggleStyle(.switch).labelsHidden()
            }
            divider
            row(icon: "menubar.rectangle", tint: .gray,
                title: tr("Значок в строке меню", "Menu bar icon"),
                subtitle: tr("Если скрыть, настройки откроются кнопкой на вкладке «Настройки» в челке", "If hidden, open settings with the button on the notch's Settings tab")) {
                Toggle("", isOn: $showMenuBarIcon).toggleStyle(.switch).labelsHidden()
            }
            divider
            row(icon: "globe", tint: .blue, title: l10n.t(.settingsLanguageSection), subtitle: nil) {
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
                    HStack(spacing: 6) {
                        Text(l10n.currentLanguage.displayName)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            divider
            Button(action: {
                OnboardingWindowController.shared.show()
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }) {
                row(icon: "sparkles.rectangle.stack.fill", tint: .cyan,
                    title: l10n.t(.settingsWelcomeBannerTitle), subtitle: l10n.t(.settingsWelcomeBannerDesc)) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.35))
                }
            }
            .buttonStyle(.plain)
            divider
            Button(action: {
                confirm(tr("Сбросить Notchy?", "Reset Notchy?"),
                        tr("Разрешения и настройки будут сброшены, приложение перезапустится. Разрешения нужно будет выдать заново.",
                           "Permissions and settings will be reset and the app will relaunch. You'll need to grant permissions again."),
                        tr("Сбросить", "Reset")) { AppCleanup.run(uninstall: false) }
            }) {
                row(icon: "arrow.counterclockwise", tint: .orange,
                    title: tr("Сбросить разрешения и настройки", "Reset permissions & settings"),
                    subtitle: tr("Помогает, если разрешения сломались после обновления", "Helps if permissions broke after an update")) { EmptyView() }
            }
            .buttonStyle(.plain)
            divider
            Button(action: {
                confirm(tr("Удалить Notchy?", "Uninstall Notchy?"),
                        tr("Приложение, его данные, настройки, разрешения, автозапуск и хуки агентов будут удалены. Приложение переместится в Корзину.",
                           "The app, its data, settings, permissions, login item and agent hooks will be removed. The app goes to the Trash."),
                        tr("Удалить", "Uninstall")) { AppCleanup.run(uninstall: true) }
            }) {
                row(icon: "trash.fill", tint: .red,
                    title: tr("Удалить приложение", "Uninstall app"),
                    subtitle: tr("Полностью, со всеми файлами", "Completely, with all its files")) { EmptyView() }
            }
            .buttonStyle(.plain)
        }
    }

    private func confirm(_ title: String, _ text: String, _ action: String, _ onOK: () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: action).hasDestructiveAction = true
        alert.addButton(withTitle: tr("Отмена", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { onOK() }
    }

    // MARK: - Building blocks

    /// A titled group: small heading, one rounded card with its rows, optional explanation underneath
    private func section<Content: View>(title: String, footer: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
                .padding(.leading, 4)
            VStack(spacing: 0, content: content)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 0.8))
            if let footer = footer {
                Text(footer)
                    .font(.system(size: 10.5, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var divider: some View {
        Divider().background(Color.white.opacity(0.08)).padding(.leading, 54)
    }

    /// Icon tile + title/subtitle + a trailing control
    private func row<Trailing: View>(icon: String, tint: Color, title: String, subtitle: String?, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.85)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = recSettings.saveFolder
        panel.level = .modalPanel
        panel.prompt = tr("Выбрать", "Select")
        panel.message = tr("Выберите папку для сохранения записей экрана", "Choose folder for screen recordings")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            recSettings.saveFolder = url
        }
    }
}

/// Reset / uninstall. The file work runs in a shell script after the app quits, so nothing writes prefs back.
enum AppCleanup {
    static func run(uninstall: Bool) {
        let id = Bundle.main.bundleIdentifier ?? "com.local.DynamicNotch"
        if uninstall {
            AgentHookManager.shared.removeHooks()
            try? SMAppService.mainApp.unregister()
        }
        let lib = "$HOME/Library"
        var script = """
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
        tccutil reset All \(id)
        defaults delete \(id)
        rm -f "\(lib)/Preferences/\(id).plist"
        """
        if uninstall {
            script += """

            rm -rf "\(lib)/Application Support/Notchy" "\(lib)/Caches/Notchy" "\(lib)/Caches/\(id)" \
              "\(lib)/HTTPStorages/\(id)" "\(lib)/HTTPStorages/\(id).binarycookies" "\(lib)/WebKit/\(id)" \
              "\(lib)/Saved Application State/\(id).savedState"
            mv "$1" "$HOME/.Trash/$(basename "$1")" 2>/dev/null || rm -rf "$1"
            """
        } else {
            script += "\nopen \"$1\""
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

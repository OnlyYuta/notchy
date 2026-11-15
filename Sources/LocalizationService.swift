import Foundation
import SwiftUI
import Combine

public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case ru = "ru"
    case en = "en"
    case fr = "fr"
    case de = "de"
    case it = "it"
    case es = "es"
    case ja = "ja"
    case zh = "zh"
    case ko = "ko"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .ru: return "🇷🇺 Русский"
        case .en: return "🇬🇧 English"
        case .fr: return "🇫🇷 Français"
        case .de: return "🇩🇪 Deutsch"
        case .it: return "🇮🇹 Italiano"
        case .es: return "🇪🇸 Español"
        case .ja: return "🇯🇵 日本語"
        case .zh: return "🇨🇳 中文"
        case .ko: return "🇰🇷 한국어"
        }
    }
    
    /// Short label for tight places
    public var shortName: String { rawValue.uppercased() }
    
    /// Picks the app language from the system's preferred languages
    public static func fromSystem() -> AppLanguage {
        for code in Locale.preferredLanguages {
            let base = code.lowercased()
            if let match = AppLanguage.allCases.first(where: { base.hasPrefix($0.rawValue) }) { return match }
        }
        return .en
    }
}

/// Text for the current language. Russian and English come from the call itself; the other languages are looked up by the
/// English text in `Translations` (and fall back to English). `{0}`, `{1}` in a text are replaced by `args`.
public func tr(_ ru: String, _ en: String) -> String {
    LocalizationService.shared.translate(ru: ru, en: en)
}

public func tr(_ ru: String, _ en: String, _ args: CVarArg...) -> String {
    var text = LocalizationService.shared.translate(ru: ru, en: en)
    for (i, arg) in args.enumerated() { text = text.replacingOccurrences(of: "{\(i)}", with: "\(arg)") }
    return text
}

public enum L10nKey: String {
    // Tabs
    case tabAgents
    case tabMusic
    case tabClipboard
    case tabRecord
    case tabSettings
    
    // Screen Recording & Replay
    case replayActive
    case replayInactive
    case saveReplayButton
    case startRecording
    case stopRecording
    case recordInstantReplay
    case recordScreen
    case recordChangeFolder
    case recordRevealInFinder
    case recordSystemAudio
    case recordMicrophone
    case settingsRecorderSection
    case settingsRecorderHotkeys
    case settingsHotkeyReplay
    case settingsHotkeyRecord
    case settingsSaveFolder
    
    // Agent status
    case agentStatusWorking
    case agentStatusDone
    case agentStatusIdle
    case agentStatusPromptReceived
    case agentStatusConfirmation
    case agentStatusNoActive
    case agentStatusProject
    
    // Music
    case musicPlaying
    case musicNoTrack
    case musicAudioPlayer
    case musicPaused
    case musicPrevious
    case musicPlayPause
    case musicNext
    
    // Clipboard
    case clipboardEmpty
    case clipboardEmptyHint
    case clipboardClear
    case clipboardClearHelp
    case clipboardChars
    case clipboardCopied
    case clipboardCount
    
    // Menu Bar
    
    // Settings
    case settingsTitle
    case settingsLanguageSection
    case settingsTabsSection
    case settingsTabsSectionDesc
    case settingsNotificationsSection
    case settingsAgentNotifications
    case settingsAgentNotificationsDesc
    case settingsMusicNotifications
    case settingsMusicNotificationsDesc
    case settingsConnectionSection
    case settingsConnectionStatus
    case settingsConnected
    case settingsDisconnected
    case settingsConnectButton
    case settingsReconnectButton
    case settingsActiveSessions
    case settingsLastSync
    case settingsAtLeastOneTabWarning
    case settingsExternalDisplaysSection
    case settingsDisableOnExternal
    case settingsDisableOnExternalDesc
    case settingsRevealOnHoverExternal
    case settingsRevealOnHoverExternalDesc
    
    // Settings - Keep Awake
    case settingsKeepAwakeTitle
    case settingsKeepAwakeDesc
    case settingsKeepAwakeStatusActive
    case settingsKeepAwakeStatusInactive
    
    // Onboarding & Permissions
    case onboardingWelcomeTitle
    case onboardingWelcomeSubtitle
    case onboardingFeatureNotchTitle
    case onboardingFeatureNotchDesc
    case onboardingFeatureAgentsTitle
    case onboardingFeatureAgentsDesc
    case onboardingFeatureMusicTitle
    case onboardingFeatureMusicDesc
    case onboardingFeatureClipboardTitle
    case onboardingFeatureClipboardDesc
    case onboardingPermissionsHeader
    case onboardingPermissionsDesc
    case onboardingPermAccessibilityTitle
    case onboardingPermAccessibilityDesc
    case onboardingPermNotificationsTitle
    case onboardingPermNotificationsDesc
    case onboardingPermScreenCaptureTitle
    case onboardingPermScreenCaptureDesc
    case onboardingPermGranted
    case onboardingPermRequired
    case onboardingPermOptional
    case onboardingPermGrantButton
    case onboardingPermOpenSettings
    case onboardingPermRelaunchApp
    case onboardingPermRelaunchTip
    case onboardingPermMoveToAppsTip
    case onboardingPermInstructionAccessibility
    case onboardingPermInstructionScreenCapture
    case recordPermissionWarning
    case onboardingGetStartedButton
    case settingsWelcomeBannerTitle
    case settingsWelcomeBannerDesc
    case settingsWelcomeBannerButton
    case recordHideNotchTitle
    case recordHideNotchDesc
    case recordMicDeviceTitle
    case subagentsWorking
}

public final class LocalizationService: ObservableObject {
    public static let shared = LocalizationService()
    
    private let userDefaultsKey = "notch_app_language"
    
    @Published public var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: userDefaultsKey)
        }
    }
    
    private init() {
        if let saved = UserDefaults.standard.string(forKey: userDefaultsKey),
           let lang = AppLanguage(rawValue: saved) {
            self.currentLanguage = lang
        } else {
            // Follow the system language when the app has a translation for it, otherwise English
            self.currentLanguage = AppLanguage.fromSystem()
        }
    }
    
    public func setLanguage(_ language: AppLanguage) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            self.currentLanguage = language
        }
    }
    
    public func t(_ key: L10nKey) -> String {
        switch currentLanguage {
        case .ru:
            return translationsRu[key] ?? translationsEn[key] ?? key.rawValue
        case .en:
            return translationsEn[key] ?? key.rawValue
        default:
            let english = translationsEn[key] ?? key.rawValue
            return Translations.table[currentLanguage]?[english] ?? english
        }
    }
    
    /// See the global `tr`
    public func translate(ru: String, en: String) -> String {
        switch currentLanguage {
        case .ru: return ru
        case .en: return en
        default: return Translations.table[currentLanguage]?[en] ?? en
        }
    }
    
    private let translationsRu: [L10nKey: String] = [
        .tabAgents: "Агенты",
        .tabMusic: "Музыка",
        .tabClipboard: "Буфер",
        .tabRecord: "Запись",
        .tabSettings: "Настройки",
        
        .replayActive: "Повтор активен",
        .replayInactive: "Повтор выключен",
        .saveReplayButton: "Сохранить повтор",
        .startRecording: "Начать запись",
        .stopRecording: "Остановить",
        .recordInstantReplay: "Мгновенный повтор",
        .recordScreen: "Запись экрана",
        .recordChangeFolder: "Выбрать папку...",
        .recordRevealInFinder: "Показать в Finder",
        .recordSystemAudio: "Звук системы",
        .recordMicrophone: "Микрофон",
        .settingsRecorderSection: "Запись экрана и повтор",
        .settingsRecorderHotkeys: "Горячие клавиши",
        .settingsHotkeyReplay: "Сохранить повтор",
        .settingsHotkeyRecord: "Старт / Стоп записи",
        .settingsSaveFolder: "Папка сохранения",
        
        .agentStatusWorking: "В работе",
        .agentStatusDone: "Готово",
        .agentStatusIdle: "В ожидании",
        .agentStatusPromptReceived: "Запрос...",
        .agentStatusConfirmation: "Подтверждение",
        .agentStatusNoActive: "Нет активных агентов",
        .agentStatusProject: "Проект",
        
        .musicPlaying: "Музыка играет",
        .musicNoTrack: "Нет трека",
        .musicAudioPlayer: "Аудиоплеер",
        .musicPaused: "Пауза",
        .musicPrevious: "Предыдущий трек",
        .musicPlayPause: "Воспроизведение / Пауза",
        .musicNext: "Следующий трек",
        
        .clipboardEmpty: "Буфер обмена пуст",
        .clipboardEmptyHint: "Скопируйте текст (⌘C) или перетащите файл, папку или фото на челку, и они появятся здесь",
        .clipboardClear: "Очистить",
        .clipboardClearHelp: "Очистить историю буфера обмена",
        .clipboardChars: "симв.",
        .clipboardCopied: "Скопировано в буфер!",
        .clipboardCount: "Записей:",
        
        
        .settingsTitle: "Настройки",
        .settingsLanguageSection: "Язык интерфейса",
        .settingsTabsSection: "Отображение вкладок",
        .settingsTabsSectionDesc: "Включите нужные вкладки для отображения в челке",
        .settingsNotificationsSection: "Уведомления",
        .settingsAgentNotifications: "Уведомления об агентах",
        .settingsAgentNotificationsDesc: "Сообщать при начале и завершении работы",
        .settingsMusicNotifications: "Смена музыкального трека",
        .settingsMusicNotificationsDesc: "Показывать название при переключении песни",
        .settingsConnectionSection: "Подключение агентов",
        .settingsConnectionStatus: "Состояние",
        .settingsConnected: "Подключено",
        .settingsDisconnected: "Не подключено",
        .settingsConnectButton: "Подключить",
        .settingsReconnectButton: "Переподключить",
        .settingsActiveSessions: "Активных сессий",
        .settingsLastSync: "Синхронизировано",
        .settingsAtLeastOneTabWarning: "Хотя бы одна вкладка должна оставаться активной",
        .settingsExternalDisplaysSection: "Внешние мониторы",
        .settingsDisableOnExternal: "Отключить на внешних мониторах",
        .settingsDisableOnExternalDesc: "Скрывает челку на подключенных внешних мониторах",
        .settingsRevealOnHoverExternal: "Выезжать при наведении",
        .settingsRevealOnHoverExternalDesc: "Челка скрыта, но выезжает при наведении на верхнюю границу",
        
        .settingsKeepAwakeTitle: "Не усыплять Mac",
        .settingsKeepAwakeDesc: "Блокирует выключение и переход в спящий режим для непрерывной работы агентов",
        .settingsKeepAwakeStatusActive: "Активен • Mac не уснет",
        .settingsKeepAwakeStatusInactive: "Отключен",
        
        .onboardingWelcomeTitle: "Добро пожаловать в Notchy",
        .onboardingWelcomeSubtitle: "Интерактивный Dynamic Island для челки вашего MacBook",
        .onboardingFeatureNotchTitle: "Нативный Dynamic Island",
        .onboardingFeatureNotchDesc: "Адаптируется под челку вашего Mac, расширяется при наведении и пропускает клики меню",
        .onboardingFeatureAgentsTitle: "Мониторинг AI Агентов",
        .onboardingFeatureAgentsDesc: "Индикация Antigravity, Claude, Codex, параллельных проектов и запросов подтверждения",
        .onboardingFeatureMusicTitle: "Управление Музыкой",
        .onboardingFeatureMusicDesc: "Живой 5-полосный аудио-эквалайзер, обложки треков и управление без наведения",
        .onboardingFeatureClipboardTitle: "История Буфера и Менюбар",
        .onboardingFeatureClipboardDesc: "Быстрый поиск скопированного текста и разгрузка переполненной строки меню",
        .onboardingPermissionsHeader: "Необходимые разрешения",
        .onboardingPermissionsDesc: "Для работы всех функций челки требуются следующие разрешения macOS:",
        .onboardingPermAccessibilityTitle: "Универсальный доступ",
        .onboardingPermAccessibilityDesc: "Требуется для управления строкой меню и глобальных горячих клавиш",
        .onboardingPermNotificationsTitle: "Уведомления",
        .onboardingPermNotificationsDesc: "Оповещения об окончании работы агентов и сохранении видео",
        .onboardingPermScreenCaptureTitle: "Запись экрана и повтор",
        .onboardingPermScreenCaptureDesc: "Требуется для мгновенного повтора (ShadowPlay) и записи экрана",
        .onboardingPermGranted: "Разрешено",
        .onboardingPermRequired: "Требуется",
        .onboardingPermOptional: "Рекомендуется",
        .onboardingPermGrantButton: "Разрешить",
        .onboardingPermOpenSettings: "Настройки...",
        .onboardingPermRelaunchApp: "Перезапустить",
        .onboardingPermRelaunchTip: "Включили тумблер? Перезапустите приложение для применения",
        .onboardingPermMoveToAppsTip: "💡 Скопируйте Notchy в «Программы» для постоянного сохранения разрешений",
        .onboardingPermInstructionAccessibility: "Включите тумблер напротив Notchy в Системных настройках",
        .onboardingPermInstructionScreenCapture: "Включите тумблер для Notchy и нажмите «Завершить и открыть заново»",
        .recordPermissionWarning: "Требуется доступ к записи экрана для сохранения повторов и видео",
        .onboardingGetStartedButton: "Начать использование",
        .settingsWelcomeBannerTitle: "Окно приветствия и разрешения",
        .settingsWelcomeBannerDesc: "Посмотреть обзор возможностей челки и проверить системные доступы",
        .settingsWelcomeBannerButton: "Открыть обзор",
        .recordHideNotchTitle: "Скрывать челку на записи",
        .recordHideNotchDesc: "Челка видна вам, но скрыта на видеозаписи и повторах",
        .recordMicDeviceTitle: "Микрофон:",
        .subagentsWorking: "субагентов в работе"
    ]
    
    private let translationsEn: [L10nKey: String] = [
        .tabAgents: "Agents",
        .tabMusic: "Music",
        .tabClipboard: "Clipboard",
        .tabRecord: "Record",
        .tabSettings: "Settings",
        
        .replayActive: "Replay Active",
        .replayInactive: "Replay Inactive",
        .saveReplayButton: "Save Replay",
        .startRecording: "Start Recording",
        .stopRecording: "Stop Recording",
        .recordInstantReplay: "Instant Replay",
        .recordScreen: "Screen Recording",
        .recordChangeFolder: "Choose Folder...",
        .recordRevealInFinder: "Show in Finder",
        .recordSystemAudio: "System Audio",
        .recordMicrophone: "Microphone",
        .settingsRecorderSection: "Screen Recording & Replay",
        .settingsRecorderHotkeys: "Keyboard Shortcuts",
        .settingsHotkeyReplay: "Save Replay",
        .settingsHotkeyRecord: "Start / Stop Recording",
        .settingsSaveFolder: "Save Folder",
        
        .agentStatusWorking: "Working",
        .agentStatusDone: "Done",
        .agentStatusIdle: "Idle",
        .agentStatusPromptReceived: "Prompt...",
        .agentStatusConfirmation: "Confirmation",
        .agentStatusNoActive: "No active agents",
        .agentStatusProject: "Project",
        
        .musicPlaying: "Playing music",
        .musicNoTrack: "No track",
        .musicAudioPlayer: "Audio Player",
        .musicPaused: "Paused",
        .musicPrevious: "Previous Track",
        .musicPlayPause: "Play / Pause",
        .musicNext: "Next Track",
        
        .clipboardEmpty: "Clipboard is empty",
        .clipboardEmptyHint: "Copy text (⌘C) or drag a file, folder or photo onto the notch, and it will appear here",
        .clipboardClear: "Clear",
        .clipboardClearHelp: "Clear clipboard history",
        .clipboardChars: "chars",
        .clipboardCopied: "Copied to clipboard!",
        .clipboardCount: "Items:",
        
        
        .settingsTitle: "Settings",
        .settingsLanguageSection: "Interface Language",
        .settingsTabsSection: "Tab Visibility",
        .settingsTabsSectionDesc: "Choose which tabs to display in the Notch",
        .settingsNotificationsSection: "Notifications",
        .settingsAgentNotifications: "Agent Status Alerts",
        .settingsAgentNotificationsDesc: "Notify when agents start or finish tasks",
        .settingsMusicNotifications: "Music Track Change",
        .settingsMusicNotificationsDesc: "Show a banner when a song changes",
        .settingsConnectionSection: "Agent Connection",
        .settingsConnectionStatus: "Status",
        .settingsConnected: "Connected",
        .settingsDisconnected: "Disconnected",
        .settingsConnectButton: "Connect",
        .settingsReconnectButton: "Reconnect",
        .settingsActiveSessions: "Active sessions",
        .settingsLastSync: "Last sync",
        .settingsAtLeastOneTabWarning: "At least one tab must remain active",
        .settingsExternalDisplaysSection: "External Displays",
        .settingsDisableOnExternal: "Disable on External Displays",
        .settingsDisableOnExternalDesc: "Hides the notch on connected external monitors",
        .settingsRevealOnHoverExternal: "Slide Out on Hover",
        .settingsRevealOnHoverExternalDesc: "Notch stays hidden, but slides out when hovering near the top edge",
        
        .settingsKeepAwakeTitle: "Keep Mac Awake",
        .settingsKeepAwakeDesc: "Prevents Mac from sleeping or shutting down for continuous agent runs",
        .settingsKeepAwakeStatusActive: "Active • Mac will stay awake",
        .settingsKeepAwakeStatusInactive: "Inactive",
        
        .onboardingWelcomeTitle: "Welcome to Notchy",
        .onboardingWelcomeSubtitle: "Interactive Dynamic Island for your MacBook notch",
        .onboardingFeatureNotchTitle: "Native Dynamic Island",
        .onboardingFeatureNotchDesc: "Adapts to your Mac notch, smoothly expands on hover, and allows click pass-through",
        .onboardingFeatureAgentsTitle: "AI Agent Monitoring",
        .onboardingFeatureAgentsDesc: "Live status for Antigravity, Claude, Codex, parallel projects, and confirmation prompts",
        .onboardingFeatureMusicTitle: "Music & Equalizer",
        .onboardingFeatureMusicDesc: "Live 5-band audio equalizer, album artwork, and controls right inside the notch",
        .onboardingFeatureClipboardTitle: "Clipboard History & Menu Bar",
        .onboardingFeatureClipboardDesc: "Quick search for copied snippets and declutter your crowded system menu bar",
        .onboardingPermissionsHeader: "Permissions Required",
        .onboardingPermissionsDesc: "To operate seamlessly and manage menu bar items, Notchy needs macOS permissions:",
        .onboardingPermAccessibilityTitle: "Accessibility",
        .onboardingPermAccessibilityDesc: "Required to interact with and manage status items in the system menu bar",
        .onboardingPermNotificationsTitle: "Notifications",
        .onboardingPermNotificationsDesc: "Alerts when AI agents finish tasks or when screen recordings are saved",
        .onboardingPermScreenCaptureTitle: "Screen Recording & Replay",
        .onboardingPermScreenCaptureDesc: "Required for Instant Replay (ShadowPlay) and screen recording",
        .onboardingPermGranted: "Granted",
        .onboardingPermRequired: "Required",
        .onboardingPermOptional: "Recommended",
        .onboardingPermGrantButton: "Grant Access",
        .onboardingPermOpenSettings: "Settings...",
        .onboardingPermRelaunchApp: "Relaunch",
        .onboardingPermRelaunchTip: "Enabled in Settings? Relaunch app to apply changes",
        .onboardingPermMoveToAppsTip: "💡 Copy Notchy to Applications to permanently preserve permissions",
        .onboardingPermInstructionAccessibility: "Turn on the toggle next to Notchy in System Settings",
        .onboardingPermInstructionScreenCapture: "Turn on the toggle for Notchy and click Quit & Reopen",
        .recordPermissionWarning: "Screen Recording permission is required for replays and video recording",
        .onboardingGetStartedButton: "Get Started",
        .settingsWelcomeBannerTitle: "Welcome & Permissions",
        .settingsWelcomeBannerDesc: "View feature walkthrough and verify macOS system permissions",
        .settingsWelcomeBannerButton: "Open Walkthrough",
        .recordHideNotchTitle: "Hide Notch in Recording",
        .recordHideNotchDesc: "Notch is visible to you, but hidden from recordings and replays",
        .recordMicDeviceTitle: "Microphone:",
        .subagentsWorking: "subagents working"
    ]
}

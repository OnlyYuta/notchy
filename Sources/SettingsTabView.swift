import SwiftUI
import AppKit

/// Вкладка в челке: только то, что нужно быстро включать и выключать. Остальное — в отдельном окне.
public struct SettingsTabView: View {
    @ObservedObject private var l10n = LocalizationService.shared
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var recorder = ScreenRecorderService.shared
    @ObservedObject private var recSettings = ScreenRecorderSettings.shared
    
    public init() {}
    
    public var body: some View {
        let ru = l10n.currentLanguage == .ru
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                // Instant replay starts/stops the background recording; permission prompts live in the service
                QuickToggle(icon: "record.circle", title: tr("Повтор", "Replay"), tint: .yellow, height: 36,
                            isOn: Binding(get: { recorder.isReplayActive }, set: { _ in recorder.toggleReplayBuffer() }))
                QuickToggle(icon: recSettings.recordMicrophone ? "mic.fill" : "mic.slash.fill", title: tr("Микрофон", "Mic"), tint: .green, height: 36,
                            isOn: Binding(get: { recSettings.recordMicrophone }, set: { on in
                                recSettings.recordMicrophone = on
                                if on && !PermissionManager.shared.isMicrophoneGranted { PermissionManager.shared.requestMicrophone() }
                            }))
                QuickToggle(icon: recSettings.recordSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill", title: tr("Звук системы", "System audio"), tint: .green, height: 36,
                            isOn: $recSettings.recordSystemAudio)
                
                Button(action: { AppSettingsWindowController.shared.show() }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 34, height: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(NotchPressButtonStyle())
                .help(tr("Все настройки…", "All settings…"))
            }
            
            HStack(spacing: 6) {
                AwakeChip()
                QuickToggle(icon: "sparkles", title: tr("Агенты", "Agents"), tint: .green, isOn: $settings.agentNotificationsEnabled)
                QuickToggle(icon: "music.note", title: tr("Музыка", "Music"), tint: .green, isOn: $settings.musicNotificationsEnabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct QuickToggle: View {
    let icon: String
    let title: String
    let tint: Color
    var height: CGFloat = 42
    @Binding var isOn: Bool
    
    var body: some View {
        Button(action: {
            withAnimation(NotchViewModel.springAnimation) { isOn.toggle() }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isOn ? tint : .white.opacity(0.4))
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(isOn ? .white : .white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn ? tint.opacity(0.16) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isOn ? tint.opacity(0.45) : Color.white.opacity(0.06), lineWidth: 0.8)
            )
        }
        .buttonStyle(NotchPressButtonStyle())
    }
}


/// "Keep awake": tap to switch on or off; while it runs the chip shows the time left (or ∞); the corner menu picks how long.
private struct AwakeChip: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var l10n = LocalizationService.shared
    
    var body: some View {
        let ru = l10n.currentLanguage == .ru
        let on = settings.preventSleepEnabled
        Button(action: {
            withAnimation(NotchViewModel.springAnimation) { settings.preventSleepEnabled.toggle() }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }) {
            VStack(spacing: 3) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(on ? .orange : .white.opacity(0.4))
                Group {
                    if on {
                        if let end = settings.keepAwakeEndsAt {
                            // Updates every 15 s: precise enough for hours, and costs nothing between ticks
                            TimelineView(.periodic(from: .now, by: 15)) { context in
                                Text(Self.remaining(until: end, now: context.date))
                            }
                        } else {
                            Text("∞")
                        }
                    } else {
                        Text(tr("Не спать", "Awake"))
                    }
                }
                .font(.system(size: 9.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(on ? .white : .white.opacity(0.5))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Color.orange.opacity(0.16) : Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(on ? Color.orange.opacity(0.45) : Color.white.opacity(0.06), lineWidth: 0.8))
        }
        .buttonStyle(NotchPressButtonStyle())
        .overlay(alignment: .topTrailing) { durationMenu(ru: ru) }
        .help(tr("Не давать Mac засыпать. Стрелка в углу: на какое время.", "Keep the Mac awake. The corner arrow sets for how long."))
    }
    
    private func durationMenu(ru: Bool) -> some View {
        Menu {
            Text(tr("Не спать в течение", "Stay awake for"))
            ForEach(KeepAwakeDuration.allCases) { duration in
                Button(action: { settings.keepAwakeDuration = duration }) {
                    Text(settings.keepAwakeDuration == duration ? "✓ \(duration.title)" : duration.title)
                }
            }
            Divider()
            Button(action: { settings.keepAwakeClosedLid.toggle() }) {
                Text((settings.keepAwakeClosedLid ? "✓ " : "") + (tr("И с закрытой крышкой (нужен пароль)", "Even with the lid closed (needs password)")))
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 18, height: 16)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 18)
        .padding(.top, 2)
        .padding(.trailing, 2)
    }
    
    private static func remaining(until end: Date, now: Date) -> String {
        let seconds = max(Int(end.timeIntervalSince(now)), 0)
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? String(format: "%d:%02d", h, m) : "\(max(m, 1)) \(tr("мин", "min"))"
    }
}

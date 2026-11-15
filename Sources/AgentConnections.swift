import SwiftUI
import Combine

public enum AgentLinkState {
    case connected      // показ включён, хук записан в конфиг агента
    case disabled       // показ выключен пользователем
    case notDetected    // агент не установлен
    case failed         // включено, агент есть, но хук не записался (например, конфиг не JSON)
}

/// Состояние подключения каждого агента; читает конфиги в фоне, чтобы не блокировать интерфейс.
public final class AgentConnections: ObservableObject {
    public static let shared = AgentConnections()

    @Published public private(set) var states: [HookAgent: AgentLinkState] = [:]

    private init() { refresh() }

    public func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let hooks = AgentHookManager.shared
            var next: [HookAgent: AgentLinkState] = [:]
            for a in HookAgent.allCases {
                if !hooks.isEnabled(a) { next[a] = .disabled }
                else if !hooks.isAgentPresent(a) { next[a] = .notDetected }
                else { next[a] = hooks.isHookInstalled(a) ? .connected : .failed }
            }
            DispatchQueue.main.async {
                withAnimation(NotchViewModel.springAnimation) { self.states = next }
            }
        }
    }

    public func state(_ a: HookAgent) -> AgentLinkState { states[a] ?? .disabled }

    public func toggle(_ a: HookAgent) {
        let turnOn = AgentHookManager.shared.isEnabled(a) == false
        AgentHookManager.shared.setEnabled(a, turnOn)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        // Мгновенная обратная связь, пока фоновая запись конфига не завершилась
        withAnimation(NotchViewModel.springAnimation) { states[a] = turnOn ? .connected : .disabled }
    }
}

extension AgentLinkState {
    var color: Color {
        switch self {
        case .connected: return Color(red: 0.20, green: 0.85, blue: 0.40)
        case .failed: return Color(red: 1.0, green: 0.82, blue: 0.0)
        case .disabled, .notDetected: return Color.white.opacity(0.3)
        }
    }

    var label: String {
        switch self {
        case .connected: return tr("Подключён", "Connected")
        case .disabled: return tr("Выключен", "Off")
        case .notDetected: return tr("Не найден", "Not found")
        case .failed: return tr("Ошибка конфига", "Config error")
        }
    }
}

/// Компактная кнопка-переключатель агента для вкладки в челке.
struct AgentConnectChip: View {
    let agent: HookAgent
    @ObservedObject private var connections = AgentConnections.shared
    @ObservedObject private var l10n = LocalizationService.shared

    var body: some View {
        let state = connections.state(agent)
        let on = state == .connected || state == .failed
        Button(action: { connections.toggle(agent) }) {
            HStack(spacing: 6) {
                AgentBadgeView(agent: agent.agentType, size: 13.0, isBreathing: false)
                    .frame(width: 18, height: 18)
                    .opacity(on ? 1.0 : 0.45)
                VStack(alignment: .leading, spacing: 0) {
                    Text(agent.agentType.displayName)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundColor(on ? .white : .white.opacity(0.6))
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        Circle().fill(state.color).frame(width: 4.5, height: 4.5)
                        Text(state.label)
                            .font(.system(size: 8.5, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? state.color.opacity(0.14) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(on ? state.color.opacity(0.45) : Color.white.opacity(0.06), lineWidth: 0.8)
            )
        }
        .buttonStyle(NotchPressButtonStyle())
        .disabled(state == .notDetected)
        .opacity(state == .notDetected ? 0.5 : 1.0)
        .onAppear { connections.refresh() }
    }
}

/// Полная строка агента для окна настроек: статус, путь к конфигу и кнопка подключения.
struct AgentConnectRow: View {
    let agent: HookAgent
    @ObservedObject private var connections = AgentConnections.shared
    @ObservedObject private var l10n = LocalizationService.shared

    var body: some View {
        let state = connections.state(agent)
        let on = state == .connected || state == .failed
        HStack(spacing: 10) {
            AgentBadgeView(agent: agent.agentType, size: 18.0, isBreathing: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.agentType.displayName)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                HStack(spacing: 5) {
                    Circle().fill(state.color).frame(width: 6, height: 6)
                    Text(state.label)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            Spacer()
            Button(action: { connections.toggle(agent) }) {
                Text(on ? (tr("Отключить", "Disconnect")) : (tr("Подключить", "Connect")))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(on ? Color.white.opacity(0.14) : Color.blue.opacity(0.85)))
            }
            .buttonStyle(NotchPressButtonStyle())
            .disabled(state == .notDetected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
        .opacity(state == .notDetected ? 0.55 : 1.0)
        .onAppear { connections.refresh() }
    }
}

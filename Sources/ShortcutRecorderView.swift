import SwiftUI
import AppKit

final class RecorderSession: ObservableObject {
    @Published var isRecording: Bool = false
    private var localEventMonitor: Any? = nil
    private var globalEventMonitor: Any? = nil
    
    func startRecording(onKey: @escaping (KeyCombo) -> Void) {
        isRecording = true
        stopMonitor()
        
        let handleKey: (NSEvent) -> Bool = { [weak self] event in
            guard let self = self else { return false }
            let cleanFlags = event.modifierFlags.intersection([.command, .option, .shift, .control]).rawValue
            if event.keyCode == 53 { // ESC
                DispatchQueue.main.async { self.stopRecording() }
                return true
            }
            if cleanFlags != 0 || (event.keyCode >= 96 && event.keyCode <= 122) {
                let combo = KeyCombo(keyCode: event.keyCode, modifiers: cleanFlags)
                DispatchQueue.main.async {
                    onKey(combo)
                    self.stopRecording()
                }
                return true
            }
            return false
        }
        
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if handleKey(event) {
                return nil
            }
            return event
        }
        
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            _ = handleKey(event)
        }
    }
    
    func stopRecording() {
        isRecording = false
        stopMonitor()
    }
    
    func stopMonitor() {
        if let m = localEventMonitor {
            NSEvent.removeMonitor(m)
            localEventMonitor = nil
        }
        if let m = globalEventMonitor {
            NSEvent.removeMonitor(m)
            globalEventMonitor = nil
        }
    }
    
    deinit {
        stopMonitor()
    }
}

public struct ShortcutRecorderView: View {
    let title: String
    @Binding var combo: KeyCombo?
    @StateObject private var session = RecorderSession()
    
    public init(title: String, combo: Binding<KeyCombo?>) {
        self.title = title
        self._combo = combo
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
            
            Spacer()
            
            HStack(spacing: 4) {
                Button(action: {
                    if session.isRecording {
                        session.stopRecording()
                    } else {
                        session.startRecording { newCombo in
                            self.combo = newCombo
                        }
                    }
                }) {
                    Text(buttonText)
                        .font(.system(size: 11.0, weight: .semibold, design: .monospaced))
                        .foregroundColor(session.isRecording ? .yellow : .white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(session.isRecording ? Color.yellow.opacity(0.2) : Color.white.opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(session.isRecording ? Color.yellow.opacity(0.6) : Color.white.opacity(0.2), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                
                if combo != nil {
                    Button(action: {
                        combo = nil
                        session.stopRecording()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help(tr("Сбросить комбинацию", "Reset shortcut"))
                }
            }
        }
        .onDisappear {
            session.stopRecording()
        }
    }
    
    private var buttonText: String {
        if session.isRecording {
            return tr("Нажмите клавиши...", "Press keys...")
        }
        if let c = combo {
            return c.displayString
        }
        return tr("Не задано", "Not set")
    }
}

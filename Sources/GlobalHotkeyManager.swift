import Foundation
import AppKit
import Carbon.HIToolbox

public final class GlobalHotkeyManager {
    public static let shared = GlobalHotkeyManager()
    
    private var globalMonitor: Any?
    private var localMonitor: Any?
    
    private init() {
        // Its hotkeys are the recorder's only: no key monitor while the Record tab is off
        if SettingsService.shared.isTabVisible(.record) { startMonitoring() }
    }
    
    deinit {
        stopMonitoring()
    }
    
    public func startMonitoring() {
        stopMonitoring()
        
        let targetMask: NSEvent.EventTypeMask = [.keyDown]
        
        // Global monitor (when other apps or games are active)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: targetMask) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        
        // Local monitor (when notch or settings window is focused)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: targetMask) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil // Consume event
            }
            return event
        }
    }
    
    public func stopMonitoring() {
        if let gm = globalMonitor {
            NSEvent.removeMonitor(gm)
            globalMonitor = nil
        }
        if let lm = localMonitor {
            NSEvent.removeMonitor(lm)
            localMonitor = nil
        }
    }
    
    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let settings = ScreenRecorderSettings.shared
        let cleanModifiers = event.modifierFlags.intersection([.command, .option, .shift, .control]).rawValue
        let keyCode = event.keyCode
        
        // Check Save Replay hotkey
        if let replayKey = settings.hotkeyReplay,
           replayKey.keyCode == keyCode && replayKey.modifiers == cleanModifiers {
            DispatchQueue.main.async {
                ScreenRecorderService.shared.saveInstantReplay()
            }
            return true
        }
        
        // Check Toggle Manual Recording hotkey
        if let recordKey = settings.hotkeyRecord,
           recordKey.keyCode == keyCode && recordKey.modifiers == cleanModifiers {
            DispatchQueue.main.async {
                ScreenRecorderService.shared.toggleManualRecording()
            }
            return true
        }
        
        return false
    }
}

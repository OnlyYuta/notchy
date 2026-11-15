import Foundation
import SwiftUI
import Combine
import CoreGraphics
import Carbon.HIToolbox
import AVFoundation

public struct AudioInputDevice: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    
    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public enum VideoResolution: String, CaseIterable, Identifiable, Codable {
    case native = "native"
    case fhd1080p = "1080p"
    case hd720p = "720p"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .native: return tr("Родное", "Native")
        case .fhd1080p: return "1080p (Full HD)"
        case .hd720p: return "720p (HD)"
        }
    }
    
    public func targetDimensions(for sourceSize: CGSize) -> (width: Int, height: Int) {
        switch self {
        case .native:
            // H.264 hardware encoder tops out at 4096x2304, so 5K/6K displays are scaled down to fit.
            let scale = min(1.0, 4096.0 / sourceSize.width, 2304.0 / sourceSize.height)
            let w = Int(sourceSize.width * scale)
            let h = Int(sourceSize.height * scale)
            return (w - (w % 2), h - (h % 2))
        case .fhd1080p:
            let aspect = sourceSize.width / max(1.0, sourceSize.height)
            let height = 1080
            let width = Int(round(Double(height) * aspect))
            // Ensure even numbers for H.264 hardware encoders
            return (width - (width % 2), height)
        case .hd720p:
            let aspect = sourceSize.width / max(1.0, sourceSize.height)
            let height = 720
            let width = Int(round(Double(height) * aspect))
            return (width - (width % 2), height)
        }
    }
}

public enum VideoFPS: Int, CaseIterable, Identifiable, Codable {
    case fps30 = 30
    case fps60 = 60
    case fps120 = 120
    
    public var id: Int { rawValue }
    public var title: String { "\(rawValue) FPS" }
}

public enum VideoBitrate: Int, CaseIterable, Identifiable, Codable {
    case low = 8_000_000      // 8 Mbps
    case medium = 16_000_000  // 16 Mbps
    case high = 30_000_000    // 30 Mbps
    case ultra = 50_000_000   // 50 Mbps
    
    public var id: Int { rawValue }
    
    public var title: String {
        let isRu = LocalizationService.shared.currentLanguage == .ru
        switch self {
        case .low: return tr("8 Mbps (Эконом)", "8 Mbps (Economy)")
        case .medium: return tr("16 Mbps (Баланс)", "16 Mbps (Balanced)")
        case .high: return tr("30 Mbps (Высокий)", "30 Mbps (High)")
        case .ultra: return tr("50 Mbps (Ультра)", "50 Mbps (Ultra)")
        }
    }
}

public enum ReplayDuration: Int, CaseIterable, Identifiable, Codable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    
    public var id: Int { rawValue }
    
    public var title: String {
        let isRu = LocalizationService.shared.currentLanguage == .ru
        let mins = rawValue / 60
        return tr("{0} мин", "{0} min", mins)
    }
}

public struct KeyCombo: Codable, Equatable {
    public var keyCode: UInt16
    public var modifiers: UInt // NSEvent.ModifierFlags rawValue
    
    public init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
    
    public var displayString: String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        
        let keyStr = keyString(for: keyCode)
        parts.append(keyStr)
        return parts.joined(separator: " ")
    }
    
    private func keyString(for code: UInt16) -> String {
        switch Int(code) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_Space: return "Space"
        default: return "Key \(code)"
        }
    }
}

public final class ScreenRecorderSettings: ObservableObject {
    public static let shared = ScreenRecorderSettings()
    
    private let kReplayEnabled = "recorder_replay_enabled"
    private let kReplayDuration = "recorder_replay_duration"
    private let kResolution = "recorder_resolution"
    private let kFPS = "recorder_fps"
    private let kBitrate = "recorder_bitrate"
    private let kRecordSystemAudio = "recorder_system_audio"
    private let kRecordMicrophone = "recorder_microphone"
    private let kSaveFolder = "recorder_save_folder"
    private let kHotkeyReplay = "recorder_hotkey_replay"
    private let kHotkeyRecord = "recorder_hotkey_record"
    private let kSelectedDisplay = "recorder_selected_display"
    private let kHideNotchOnRecording = "recorder_hide_notch"
    private let kSelectedMicrophoneID = "recorder_mic_id"
    
    @Published public var hideNotchOnRecording: Bool {
        didSet {
            UserDefaults.standard.set(hideNotchOnRecording, forKey: kHideNotchOnRecording)
            ScreenRecorderService.shared.updateWindowExclusion()
        }
    }
    
    @Published public var selectedMicrophoneID: String {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: kSelectedMicrophoneID)
        }
    }
    
    @Published public private(set) var availableMicrophones: [AudioInputDevice] = []
    
    public var currentMicrophoneName: String {
        if selectedMicrophoneID.isEmpty {
            if let def = availableMicrophones.first(where: { $0.isDefault }) {
                return def.name
            }
            return tr("По умолчанию", "Default")
        }
        if let found = availableMicrophones.first(where: { $0.id == selectedMicrophoneID }) {
            return found.name
        }
        return tr("По умолчанию", "Default")
    }
    
    public func refreshMicrophones() {
        let discoveredDevices: [AVCaptureDevice]
        if #available(macOS 14.0, *) {
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            )
            discoveredDevices = session.devices
        } else {
            discoveredDevices = AVCaptureDevice.devices(for: .audio)
        }
        let defaultDevice = AVCaptureDevice.default(for: .audio)
        let defaultName = defaultDevice?.localizedName ?? (tr("Системный", "System"))
        
        var list: [AudioInputDevice] = []
        let defaultTitle = tr("По умолчанию ({0})", "Default ({0})", defaultName)
        list.append(AudioInputDevice(id: "", name: defaultTitle, isDefault: true))
        
        for dev in discoveredDevices {
            list.append(AudioInputDevice(id: dev.uniqueID, name: dev.localizedName, isDefault: false))
        }
        
        DispatchQueue.main.async {
            self.availableMicrophones = list
        }
    }
    
    @Published public var replayEnabled: Bool {
        didSet { UserDefaults.standard.set(replayEnabled, forKey: kReplayEnabled) }
    }
    
    @Published public var replayDuration: ReplayDuration {
        didSet { UserDefaults.standard.set(replayDuration.rawValue, forKey: kReplayDuration) }
    }
    
    @Published public var resolution: VideoResolution {
        didSet { UserDefaults.standard.set(resolution.rawValue, forKey: kResolution) }
    }
    
    @Published public var fps: VideoFPS {
        didSet { UserDefaults.standard.set(fps.rawValue, forKey: kFPS) }
    }
    
    @Published public var bitrate: VideoBitrate {
        didSet { UserDefaults.standard.set(bitrate.rawValue, forKey: kBitrate) }
    }
    
    @Published public var recordSystemAudio: Bool {
        didSet { UserDefaults.standard.set(recordSystemAudio, forKey: kRecordSystemAudio) }
    }
    
    @Published public var recordMicrophone: Bool {
        didSet { UserDefaults.standard.set(recordMicrophone, forKey: kRecordMicrophone) }
    }
    
    @Published public var saveFolder: URL {
        didSet { UserDefaults.standard.set(saveFolder.path, forKey: kSaveFolder) }
    }
    
    @Published public var hotkeyReplay: KeyCombo? {
        didSet {
            if let combo = hotkeyReplay, let data = try? JSONEncoder().encode(combo) {
                UserDefaults.standard.set(data, forKey: kHotkeyReplay)
            } else {
                UserDefaults.standard.removeObject(forKey: kHotkeyReplay)
            }
        }
    }
    
    @Published public var hotkeyRecord: KeyCombo? {
        didSet {
            if let combo = hotkeyRecord, let data = try? JSONEncoder().encode(combo) {
                UserDefaults.standard.set(data, forKey: kHotkeyRecord)
            } else {
                UserDefaults.standard.removeObject(forKey: kHotkeyRecord)
            }
        }
    }
    
    @Published public var selectedDisplayID: CGDirectDisplayID? {
        didSet {
            if let id = selectedDisplayID {
                UserDefaults.standard.set(Int(id), forKey: kSelectedDisplay)
            } else {
                UserDefaults.standard.removeObject(forKey: kSelectedDisplay)
            }
        }
    }
    
    private init() {
        if UserDefaults.standard.object(forKey: kHideNotchOnRecording) != nil {
            self.hideNotchOnRecording = UserDefaults.standard.bool(forKey: kHideNotchOnRecording)
        } else {
            self.hideNotchOnRecording = true
        }
        
        self.replayEnabled = UserDefaults.standard.bool(forKey: kReplayEnabled)
        
        let durRaw = UserDefaults.standard.integer(forKey: kReplayDuration)
        self.replayDuration = ReplayDuration(rawValue: durRaw) ?? .fiveMinutes
        
        let resRaw = UserDefaults.standard.string(forKey: kResolution) ?? VideoResolution.fhd1080p.rawValue
        self.resolution = VideoResolution(rawValue: resRaw) ?? .fhd1080p
        
        let fpsRaw = UserDefaults.standard.integer(forKey: kFPS)
        self.fps = VideoFPS(rawValue: fpsRaw) ?? .fps60
        
        let bitRaw = UserDefaults.standard.integer(forKey: kBitrate)
        self.bitrate = VideoBitrate(rawValue: bitRaw) ?? .medium
        
        if UserDefaults.standard.object(forKey: kRecordSystemAudio) != nil {
            self.recordSystemAudio = UserDefaults.standard.bool(forKey: kRecordSystemAudio)
        } else {
            self.recordSystemAudio = true
        }
        
        self.recordMicrophone = UserDefaults.standard.bool(forKey: kRecordMicrophone)
        self.selectedMicrophoneID = UserDefaults.standard.string(forKey: kSelectedMicrophoneID) ?? ""
        
        if let path = UserDefaults.standard.string(forKey: kSaveFolder), !path.isEmpty {
            self.saveFolder = URL(fileURLWithPath: path)
        } else {
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            let folder = movies.appendingPathComponent("Notchy")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.saveFolder = folder
        }
        
        // Default hotkeys: Option + Shift + S for Replay, Option + Shift + R for Record
        if let data = UserDefaults.standard.data(forKey: kHotkeyReplay),
           let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            self.hotkeyReplay = combo
        } else {
            let optShift = NSEvent.ModifierFlags([.option, .shift]).rawValue
            self.hotkeyReplay = KeyCombo(keyCode: UInt16(kVK_ANSI_S), modifiers: optShift)
        }
        
        if let data = UserDefaults.standard.data(forKey: kHotkeyRecord),
           let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            self.hotkeyRecord = combo
        } else {
            let optShift = NSEvent.ModifierFlags([.option, .shift]).rawValue
            self.hotkeyRecord = KeyCombo(keyCode: UInt16(kVK_ANSI_R), modifiers: optShift)
        }
        
        let dispInt = UserDefaults.standard.integer(forKey: kSelectedDisplay)
        self.selectedDisplayID = dispInt > 0 ? CGDirectDisplayID(dispInt) : nil
        
        refreshMicrophones()
        
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshMicrophones()
        }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshMicrophones()
        }
    }
}

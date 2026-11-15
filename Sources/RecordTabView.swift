import SwiftUI
import ScreenCaptureKit
import AppKit

public struct RecordTabView: View {
    @ObservedObject private var recorder = ScreenRecorderService.shared
    @ObservedObject private var settings = ScreenRecorderSettings.shared
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var l10n = LocalizationService.shared
    
    public init() {}
    
    private var friendlyFolderPath: String {
        let path = settings.saveFolder.path
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
    
    private var folderDisplayName: String {
        let name = settings.saveFolder.lastPathComponent
        return name.isEmpty ? tr("Папка", "Folder") : name
    }
    
    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 7) {
                // Permission Warning (if Screen Recording access not yet granted or pending restart)
                if !permissions.isScreenCaptureGranted {
                    permissionWarningBanner
                }
                
                // Two columns keep the card short: replay on the left, manual recording + options on the right
                HStack(alignment: .top, spacing: 8) {
                    replaySection
                        .frame(maxWidth: .infinity)
                    
                    VStack(spacing: 5) {
                        recordingSection
                        audioChips
                        folderAndMore
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .onAppear {
            recorder.refreshDisplays()
        }
    }
    
    // MARK: - Subviews
    
    private var permissionWarningBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .font(.system(size: 11))
            
            VStack(alignment: .leading, spacing: 1) {
                Text(l10n.t(.recordPermissionWarning))
                    .font(.system(size: 10.0, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(tr("Включили тумблер? Нажмите «Перезапуск» для применения", "Toggled ON? Click Relaunch to apply"))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
            }
            
            Spacer()
            
            Button(action: {
                permissions.requestScreenCapture()
            }) {
                Text(tr("Настройки", "Settings"))
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            
            Button(action: {
                permissions.restartApplication()
            }) {
                HStack(spacing: 2.5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8.5, weight: .bold))
                    Text(tr("Перезапуск", "Relaunch"))
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color.green))
            }
            .buttonStyle(.plain)
            .help(tr("Перезапустить Notchy для применения выданного разрешения", "Relaunch Notchy to apply granted permission"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.35), lineWidth: 1))
        )
    }
    
    private var replaySection: some View {
        VStack(spacing: 6) {
            // Header: what it is + the one switch that matters
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(recorder.isReplayActive ? .yellow : .white.opacity(0.4))
                
                Text(l10n.t(.recordInstantReplay))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                
                Spacer(minLength: 0)
                
                Toggle("", isOn: Binding(
                    get: { recorder.isReplayActive },
                    set: { _ in recorder.toggleReplayBuffer() }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .yellow))
                .scaleEffect(0.65)
                .frame(width: 34, height: 18)
                .help(recorder.isReplayActive ? l10n.t(.replayActive) : l10n.t(.replayInactive))
            }
            
            // How much to keep
            HStack(spacing: 3) {
                ForEach(ReplayDuration.allCases) { dur in
                    Button(action: { settings.replayDuration = dur }) {
                        Text(dur.title)
                            .font(.system(size: 10.0, weight: settings.replayDuration == dur ? .bold : .medium, design: .rounded))
                            .foregroundColor(settings.replayDuration == dur ? .black : .white.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(settings.replayDuration == dur ? Color.yellow : Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // The action
            Button(action: { recorder.saveInstantReplay() }) {
                HStack(spacing: 6) {
                    if recorder.isSavingReplay {
                        ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                    }
                    Text(l10n.t(.saveReplayButton))
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundColor(recorder.isReplayActive ? .black : .white.opacity(0.45))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(recorder.isReplayActive ? Color.yellow : Color.white.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
            .disabled(!recorder.isReplayActive || recorder.isSavingReplay)
            .help(settings.hotkeyReplay?.displayString ?? "")
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
    }
    
    private var recordingSection: some View {
        Button(action: { recorder.toggleManualRecording() }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .frame(width: 16, height: 16)
                
                Text(recorder.isRecording ? l10n.t(.stopRecording) : l10n.t(.startRecording))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                if recorder.isRecording {
                    Text(recorder.recordingDurationText)
                        .font(.system(size: 11.0, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                }
                
                Spacer(minLength: 0)
                
                if !recorder.isRecording, let shortcut = settings.hotkeyRecord {
                    Text(shortcut.displayString)
                        .font(.system(size: 10.0, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(recorder.isRecording ? Color.red.opacity(0.18) : Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(recorder.isRecording ? Color.red.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
    
    /// What gets recorded: two clearly labelled switches. Everything rarely changed lives in the "more" menu.
    private var audioChips: some View {
        HStack(spacing: 5) {
            audioChip(icon: settings.recordSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                      title: tr("Звук", "Sound"),
                      isOn: settings.recordSystemAudio) {
                settings.recordSystemAudio.toggle()
            }
            .help(l10n.t(.recordSystemAudio))
            
            HStack(spacing: 2) {
                audioChip(icon: settings.recordMicrophone ? "mic.fill" : "mic.slash.fill",
                          title: tr("Микрофон", "Mic"),
                          isOn: settings.recordMicrophone) {
                    settings.recordMicrophone.toggle()
                    if settings.recordMicrophone && !PermissionManager.shared.isMicrophoneGranted {
                        PermissionManager.shared.requestMicrophone()
                    }
                }
                .help(l10n.t(.recordMicrophone))
                
                microphonePicker
            }
        }
    }
    
    /// Device list right next to the Microphone switch (one flat menu, no nested submenu).
    private var microphonePicker: some View {
        Menu {
            Text(tr("Устройство ввода", "Input device"))
            ForEach(settings.availableMicrophones) { dev in
                Button(action: { settings.selectedMicrophoneID = dev.id }) {
                    let selected = (settings.selectedMicrophoneID.isEmpty && dev.id.isEmpty) || settings.selectedMicrophoneID == dev.id
                    Text(selected ? "✓ \(dev.name)" : dev.name)
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(settings.recordMicrophone ? .green : .white.opacity(0.45))
                .frame(width: 18, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(settings.recordMicrophone ? Color.green.opacity(0.14) : Color.white.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 18)
        .help(settings.currentMicrophoneName)
        .onAppear { settings.refreshMicrophones() }
    }
    
    private func audioChip(icon: String, title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 10, weight: .semibold, design: .rounded)).lineLimit(1)
            }
            .foregroundColor(isOn ? .green : .white.opacity(0.45))
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? Color.green.opacity(0.14) : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
    
    /// Save location (click to open it) plus a menu with the advanced options.
    private var folderAndMore: some View {
        HStack(spacing: 5) {
            Button(action: { NSWorkspace.shared.open(settings.saveFolder) }) {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill").font(.system(size: 10)).foregroundColor(.cyan)
                    Text(folderDisplayName)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("\(l10n.t(.recordRevealInFinder)): \(friendlyFolderPath)")
            
            moreMenu
        }
    }
    
    private var moreMenu: some View {
        return Menu {
            Button(l10n.t(.recordChangeFolder)) { chooseSaveFolder() }
            
            Divider()
            Menu(tr("Разрешение", "Resolution")) {
                ForEach(VideoResolution.allCases) { res in
                    Button(action: { settings.resolution = res }) {
                        Text(settings.resolution == res ? "✓ \(res.title)" : res.title)
                    }
                }
            }
            Menu(tr("Частота кадров", "Frame rate")) {
                ForEach(VideoFPS.allCases) { f in
                    Button(action: { settings.fps = f }) {
                        Text(settings.fps == f ? "✓ \(f.title)" : f.title)
                    }
                }
            }
            Menu(tr("Битрейт", "Bitrate")) {
                ForEach(VideoBitrate.allCases) { b in
                    Button(action: { settings.bitrate = b }) {
                        Text(settings.bitrate == b ? "✓ \(b.title)" : b.title)
                    }
                }
            }
            if recorder.availableDisplays.count > 1 {
                Menu(tr("Экран", "Display")) {
                    ForEach(recorder.availableDisplays, id: \.displayID) { disp in
                        Button(action: { settings.selectedDisplayID = disp.displayID }) {
                            let name = tr("Экран {0}", "Display {0}", disp.displayID)
                            Text(settings.selectedDisplayID == disp.displayID ? "✓ \(name)" : name)
                        }
                    }
                }
            }
            Divider()
            Button(action: { settings.hideNotchOnRecording.toggle() }) {
                Text((settings.hideNotchOnRecording ? "✓ " : "") + (tr("Скрывать челку на записи", "Hide notch in recordings")))
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26)
        .help(tr("Качество, микрофон, папка и другие параметры", "Quality, microphone, folder and other options"))
    }
    
    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = tr("Выбрать", "Select")
        panel.directoryURL = settings.saveFolder
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolder = url
        }
    }
}

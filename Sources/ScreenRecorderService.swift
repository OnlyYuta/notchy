import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Combine
import AppKit

public enum RecordingState: Equatable {
    case idle
    case manualRecording
    case replayBuffering
}

public final class ScreenRecorderService: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    public static let shared = ScreenRecorderService()
    
    // Published state for UI
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var isReplayActive: Bool = false
    // Not @Published: only the text is shown, and republishing a Double every tick re-rendered observers needlessly
    public private(set) var recordingDuration: TimeInterval = 0.0
    @Published public private(set) var recordingDurationText: String = "00:00"
    @Published public private(set) var availableDisplays: [SCDisplay] = []
    @Published public private(set) var isSavingReplay: Bool = false
    @Published public private(set) var lastSavedReplayURL: URL? = nil
    @Published public private(set) var errorMessage: String? = nil
    
    private let settings = ScreenRecorderSettings.shared
    private let bufferManager = ReplayBufferManager.shared
    
    // ScreenCaptureKit stream
    private var stream: SCStream?
    private var activeFilter: SCContentFilter?
    private var activeConfiguration: SCStreamConfiguration?
    
    // Encoding & Writer
    private let writeQueue = DispatchQueue(label: "com.local.notchy.recorder.write", qos: .userInitiated)
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var micWriterInput: AVAssetWriterInput?
    private var isWriterSessionStarted = false
    private var firstSampleTime: CMTime = .invalid
    
    // Encoder profile of the running stream. The always-on replay buffer follows the user's FPS but caps
    // bitrate (<= 16 Mbps) and size (<= 1080p) because it runs for hours; manual recordings use the settings as is.
    private var encodeFPS = 30
    private var encodeBitrate = 8_000_000
    
    // Current file tracking
    private var currentFileURL: URL?
    private var currentChunkStartTime: Date?
    private var chunkTimer: Timer?
    private var durationTimer: Timer?
    private var recordingStartDate: Date?
    
    // Notification for notch wing expansion
    public let replaySavedSubject = PassthroughSubject<URL, Never>()
    private var currentDisplay: SCDisplay?
    private var settingsObserver: AnyCancellable?
    
    private override init() {
        super.init()
        // The replay stream reads the encoder settings only when it starts, so restart it when they change.
        settingsObserver = Publishers.Merge3(settings.$resolution.map { _ in () }, settings.$fps.map { _ in () }, settings.$bitrate.map { _ in () })
            .dropFirst(3)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self = self, self.isReplayActive, !self.isRecording, !self.isTransitioning else { return }
                self.stopReplayBuffer { self.startReplayBuffer() }
            }
        // Do NOT call SCShareableContent on launch if permission is not granted yet!
        if PermissionManager.shared.isScreenCaptureGranted {
            refreshDisplays()
            if settings.replayEnabled {
                startReplayBuffer()
            }
        } else {
            // Assign default main screen display ID via NSScreen without touching ScreenCaptureKit
            if let main = NSScreen.main,
               let screenNum = main.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                if settings.selectedDisplayID == nil {
                    settings.selectedDisplayID = screenNum
                }
            }
        }
    }
    
    // MARK: - Display Enumeration
    
    public func refreshDisplays() {
        guard PermissionManager.shared.isScreenCaptureGranted else {
            if let main = NSScreen.main,
               let screenNum = main.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                if settings.selectedDisplayID == nil {
                    settings.selectedDisplayID = screenNum
                }
            }
            return
        }
        
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            guard let self = self, let content = content else { return }
            DispatchQueue.main.async {
                self.availableDisplays = content.displays
                if self.settings.selectedDisplayID == nil, let main = content.displays.first {
                    self.settings.selectedDisplayID = main.displayID
                }
            }
        }
    }
    
    // MARK: - Manual Recording Control
    
    /// A stream is starting or stopping: rapid start/stop presses would otherwise run two streams or writers at once
    private var isTransitioning = false
    
    public func startManualRecording() {
        guard !isRecording, !isTransitioning else { return }
        
        PermissionManager.shared.checkScreenCapture()
        guard PermissionManager.shared.isScreenCaptureGranted else {
            PermissionManager.shared.requestScreenCapture()
            self.errorMessage = tr("Требуется разрешение на запись экрана", "Screen recording permission is required")
            return
        }
        
        if settings.recordMicrophone && !PermissionManager.shared.isMicrophoneGranted {
            PermissionManager.shared.requestMicrophone()
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "Recording_\(formatter.string(from: Date())).mp4"
        try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
        let outputURL = settings.saveFolder.appendingPathComponent(filename)
        
        // The replay buffer is paused during a manual recording; its stream must be fully stopped first
        let wasReplay = isReplayActive
        isTransitioning = true
        let begin = { [weak self] in
            guard let self = self else { return }
            self.startCaptureStream(outputURL: outputURL, isReplayChunk: false) { [weak self] success in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isTransitioning = false
                    if success {
                        self.isRecording = true
                        self.recordingDuration = 0.0
                        self.recordingDurationText = "00:00"
                        self.startDurationTimer()
                    } else if wasReplay {
                        self.startReplayBuffer()
                    }
                }
            }
        }
        if wasReplay { stopReplayBuffer(completion: begin) } else { begin() }
    }
    
    public func stopManualRecording(completion: ((URL?) -> Void)? = nil) {
        guard isRecording, !isTransitioning else {
            completion?(nil)
            return
        }
        
        isTransitioning = true
        stopDurationTimer()
        let targetURL = currentFileURL
        
        stopCaptureStream { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isTransitioning = false
                self.isRecording = false
                self.recordingDuration = 0.0
                self.recordingDurationText = "00:00"
                if let url = targetURL {
                    let isRu = LocalizationService.shared.currentLanguage == .ru
                    let title = tr("Запись экрана завершена", "Screen Recording Finished")
                    self.notifyUser(title: title, body: url.lastPathComponent)
                }
                completion?(targetURL)
                
                // Resume replay buffer if user has it enabled
                if self.settings.replayEnabled {
                    self.startReplayBuffer()
                }
            }
        }
    }
    
    /// The Record tab switched off: save a running recording and stop the replay buffer (its setting is kept, so
    /// switching the tab back on resumes it)
    public func setEnabled(_ on: Bool) {
        if on {
            if settings.replayEnabled { startReplayBuffer() }
            return
        }
        if isRecording {
            stopManualRecording()
        }
        stopReplayBuffer()
        // A stream still starting gets stopped once it has started
        if isTransitioning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, !SettingsService.shared.isTabVisible(.record) else { return }
                self.setEnabled(false)
            }
        }
    }
    
    public func toggleManualRecording() {
        if isRecording {
            stopManualRecording()
        } else {
            startManualRecording()
        }
    }
    
    // MARK: - Instant Replay Control
    
    public func startReplayBuffer() {
        guard !isRecording && !isReplayActive && !isTransitioning, SettingsService.shared.isTabVisible(.record) else { return }
        
        PermissionManager.shared.checkScreenCapture()
        guard PermissionManager.shared.isScreenCaptureGranted else { return }
        
        isTransitioning = true
        let chunkURL = bufferManager.createNewChunkURL()
        startCaptureStream(outputURL: chunkURL, isReplayChunk: true) { [weak self] success in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isTransitioning = false
                if success {
                    self.isReplayActive = true
                    self.startChunkRotationTimer()
                }
            }
        }
    }
    
    public func stopReplayBuffer(completion: (() -> Void)? = nil) {
        guard isReplayActive else { completion?(); return }
        stopChunkRotationTimer()
        stopCaptureStream { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isReplayActive = false
                self.bufferManager.clearBuffer()
                completion?()
            }
        }
    }
    
    public func toggleReplayBuffer() {
        if isReplayActive {
            settings.replayEnabled = false
            stopReplayBuffer()
        } else {
            PermissionManager.shared.checkScreenCapture()
            guard PermissionManager.shared.isScreenCaptureGranted else {
                PermissionManager.shared.requestScreenCapture()
                self.errorMessage = tr("Требуется разрешение на запись экрана", "Screen recording permission is required")
                return
            }
            if settings.recordMicrophone {
                PermissionManager.shared.checkMicrophone()
                if !PermissionManager.shared.isMicrophoneGranted {
                    PermissionManager.shared.requestMicrophone { granted in
                        if !granted {
                            NSLog("⚠️ Notchy: Microphone permission denied for replay buffer")
                        }
                    }
                }
            }
            settings.replayEnabled = true
            startReplayBuffer()
        }
    }
    
    public func saveInstantReplay() {
        guard isReplayActive, !isSavingReplay else {
            if !isReplayActive {
                let isRu = LocalizationService.shared.currentLanguage == .ru
                self.errorMessage = tr("Мгновенный повтор отключен в настройках", "Instant Replay is disabled in settings")
            }
            return
        }
        
        isSavingReplay = true
        
        // Finalize current active chunk first so the latest seconds are included
        rotateReplayChunk { [weak self] in
            guard let self = self else { return }
            let durationSeconds = Double(self.settings.replayDuration.rawValue)
            
            self.bufferManager.exportReplay(durationSeconds: durationSeconds, outputFolder: self.settings.saveFolder) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.isSavingReplay = false
                    switch result {
                    case .success(let url):
                        self.lastSavedReplayURL = url
                        self.replaySavedSubject.send(url)
                        let title = tr("⚡️ Мгновенный повтор сохранен!", "⚡️ Instant Replay Saved!")
                        let body = tr("Файл: {0}", "File: {0}", url.lastPathComponent)
                        self.notifyUser(title: title, body: body)
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
    
    // MARK: - Window Exclusion (Hide Notch from Recording)
    
    // Hiding our windows from the capture makes WindowServer compose a second, separate copy of the screen for every
    // captured frame (measured: roughly +30 points of CPU on a 1080p/30 fps stream). The idle notch is just the black
    // pill over the hardware cut-out and is invisible in a recording anyway, so the exclusion is applied only while
    // the notch is actually expanded (hovered, event wings, recording badge).
    private var notchExpanded = false
    private var notchCollapseWork: DispatchWorkItem?
    
    public func setNotchExpanded(_ expanded: Bool) {
        notchCollapseWork?.cancel()
        notchCollapseWork = nil
        if expanded {
            guard !notchExpanded else { return }
            notchExpanded = true
            updateWindowExclusion()
        } else if notchExpanded {
            // Keep hiding until the collapse animation has finished
            let work = DispatchWorkItem { [weak self] in
                self?.notchExpanded = false
                self?.updateWindowExclusion()
            }
            notchCollapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }
    
    public func resolveExcludedWindows(from windows: [SCWindow]) -> [SCWindow] {
        guard settings.hideNotchOnRecording, notchExpanded else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myBundle = Bundle.main.bundleIdentifier
        return windows.filter { win in
            if let app = win.owningApplication {
                if app.processID == myPID { return true }
                if let myBundle = myBundle, app.bundleIdentifier == myBundle { return true }
            }
            return false
        }
    }
    
    public func updateWindowExclusion() {
        guard let stream = self.stream, let display = self.currentDisplay else { return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self = self, let content = content, error == nil else { return }
            let excluded = self.resolveExcludedWindows(from: content.windows)
            let newFilter = SCContentFilter(display: display, excludingWindows: excluded)
            self.activeFilter = newFilter
            stream.updateContentFilter(newFilter) { updateError in
                if let err = updateError {
                    NSLog("⚠️ Notchy: Failed to update content filter: %@", err.localizedDescription)
                } else {
                    NSLog("✅ Notchy: Window exclusion updated (hideNotch = %d, excluded %ld windows)", self.settings.hideNotchOnRecording, excluded.count)
                }
            }
        }
    }
    
    // MARK: - Stream & Pipeline Management
    
    private func startCaptureStream(outputURL: URL, isReplayChunk: Bool, completion: @escaping (Bool) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self, let content = content, error == nil else {
                completion(false)
                return
            }
            
            // Choose display
            let display: SCDisplay
            if let selectedID = self.settings.selectedDisplayID,
               let match = content.displays.first(where: { $0.displayID == selectedID }) {
                display = match
            } else if let main = content.displays.first {
                display = main
            } else {
                completion(false)
                return
            }
            
            self.currentDisplay = display
            let excluded = self.resolveExcludedWindows(from: content.windows)
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            self.activeFilter = filter
            
            // Extreme Resource Optimization: Hardware Scaling & NV12 Pixel Format
            // SCDisplay reports points; use the real pixel size so "Native" is full Retina resolution.
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            let sourceSize = CGSize(width: mode?.pixelWidth ?? display.width, height: mode?.pixelHeight ?? display.height)
            let resolution: VideoResolution = (isReplayChunk && self.settings.resolution == .native) ? .fhd1080p : self.settings.resolution
            let targetDim = resolution.targetDimensions(for: sourceSize)
            self.encodeFPS = self.settings.fps.rawValue
            self.encodeBitrate = isReplayChunk ? min(self.settings.bitrate.rawValue, 16_000_000) : self.settings.bitrate.rawValue
            
            let config = SCStreamConfiguration()
            config.width = targetDim.width
            config.height = targetDim.height
            config.scalesToFit = true
            // NV12 is native GPU zero-copy hardware format on macOS
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.encodeFPS))
            config.showsCursor = true
            config.queueDepth = 3 // Prevents memory accumulation
            
            if #available(macOS 13.0, *), self.settings.recordSystemAudio {
                config.capturesAudio = true
                config.sampleRate = 48000
                config.channelCount = 2
            }
            
            if #available(macOS 15.0, *), self.settings.recordMicrophone {
                config.captureMicrophone = true
                let micID = self.settings.selectedMicrophoneID
                if !micID.isEmpty {
                    config.microphoneCaptureDeviceID = micID
                }
            }
            
            self.activeConfiguration = config
            
            // Prepare hardware AVAssetWriter
            do {
                try self.writeQueue.sync { try self.setupWriter(outputURL: outputURL, width: targetDim.width, height: targetDim.height) }
            } catch {
                completion(false)
                return
            }
            
            self.currentFileURL = outputURL
            self.currentChunkStartTime = Date()
            
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.writeQueue)
                if #available(macOS 13.0, *), self.settings.recordSystemAudio {
                    try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.writeQueue)
                }
                if #available(macOS 15.0, *), self.settings.recordMicrophone {
                    try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: self.writeQueue)
                }
                newStream.startCapture { startError in
                    if startError == nil {
                        self.stream = newStream
                        completion(true)
                    } else {
                        self.finalizeWriter { completion(false) }
                    }
                }
            } catch {
                self.finalizeWriter { completion(false) }
            }
        }
    }
    
    private func stopCaptureStream(completion: @escaping () -> Void) {
        guard let activeStream = self.stream else {
            self.finalizeWriter { completion() }
            return
        }
        
        activeStream.stopCapture { [weak self] _ in
            guard let self = self else {
                completion()
                return
            }
            self.stream = nil
            self.finalizeWriter {
                completion()
            }
        }
    }
    
    // Rotate to a new rolling chunk every 30 seconds
    private func rotateReplayChunk(completion: (() -> Void)? = nil) {
        writeQueue.async { [weak self] in
            guard let self = self, self.isReplayActive else {
                completion?()
                return
            }
            
            let oldURL = self.currentFileURL
            let oldStart = self.currentChunkStartTime ?? Date()
            let duration = Date().timeIntervalSince(oldStart)
            
            // Finish current writer
            self.finalizeWriter { [weak self] in
                guard let self = self else {
                    completion?()
                    return
                }
                
                if let url = oldURL, duration > 1.0 {
                    let maxRetention = Double(self.settings.replayDuration.rawValue)
                    self.bufferManager.registerCompletedChunk(
                        url: url,
                        startTime: oldStart,
                        duration: duration,
                        maxRetentionSeconds: maxRetention
                    )
                }
                
                // If replay is still active, immediately start next chunk
                if self.isReplayActive {
                    let nextURL = self.bufferManager.createNewChunkURL()
                    guard let cfg = self.activeConfiguration else {
                        completion?()
                        return
                    }
                    // finishWriting calls back on AVFoundation's queue: the writer belongs to writeQueue
                    self.writeQueue.sync { try? self.setupWriter(outputURL: nextURL, width: cfg.width, height: cfg.height) }
                    self.currentFileURL = nextURL
                    self.currentChunkStartTime = Date()
                }
                completion?()
            }
        }
    }
    
    // MARK: - AVAssetWriter Setup (Hardware VideoToolbox)
    
    private func setupWriter(outputURL: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: outputURL)
        
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: encodeBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: encodeFPS,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        
        if writer.canAdd(videoInput) {
            writer.add(videoInput)
            self.videoWriterInput = videoInput
        }
        
        // System Audio Input
        if #available(macOS 13.0, *), settings.recordSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                self.audioWriterInput = audioInput
            }
        }
        
        // Microphone Audio Input
        if #available(macOS 15.0, *), settings.recordMicrophone {
            // Mono: a microphone is one channel, upmixing it to stereo only doubled the AAC work
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96000
            ]
            let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            micInput.expectsMediaDataInRealTime = true
            if writer.canAdd(micInput) {
                writer.add(micInput)
                self.micWriterInput = micInput
            }
        }
        
        writer.startWriting()
        self.assetWriter = writer
        self.isWriterSessionStarted = false
        self.firstSampleTime = .invalid
    }
    
    private func finalizeWriter(completion: @escaping () -> Void) {
        writeQueue.async { [weak self] in
            guard let self = self, let writer = self.assetWriter else {
                completion()
                return
            }
            // Detach first: a second stop can't finish the same writer again (AVFoundation throws), and the old
            // writer's late completion can't clear the next recording's writer.
            let inputs = [self.videoWriterInput, self.audioWriterInput, self.micWriterInput]
            let sessionStarted = self.isWriterSessionStarted
            self.assetWriter = nil
            self.videoWriterInput = nil
            self.audioWriterInput = nil
            self.micWriterInput = nil
            self.isWriterSessionStarted = false
            
            guard writer.status == .writing else {
                NSLog("❌ Notchy: Cannot finalize, writer status is %ld: %@", writer.status.rawValue, String(describing: writer.error))
                completion()
                return
            }
            // No frame reached the writer (stopped right after starting): finishing a sessionless writer throws
            guard sessionStarted else {
                writer.cancelWriting()
                completion()
                return
            }
            inputs.forEach { $0?.markAsFinished() }
            writer.finishWriting {
                if writer.status == .completed {
                    NSLog("✅ Notchy: Video successfully finalized and saved!")
                } else {
                    NSLog("❌ Notchy: finishWriting failed with status %ld: %@", writer.status.rawValue, String(describing: writer.error))
                }
                completion()
            }
        }
    }
    
    // MARK: - SCStreamOutput Callback
    
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        
        // 1. For video: must contain an image buffer and frame status must be complete
        if type == .screen {
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            
            if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
               let attachments = attachmentsArray.first,
               let statusRaw = attachments[SCStreamFrameInfo.status.rawValue as CFString] as? Int,
               let status = SCFrameStatus(rawValue: statusRaw),
               status != .complete {
                return // Discard idle heartbeats, dropped frames, and blank frames
            }
        }
        
        // 2. For audio: must contain real audio samples
        if type == .audio {
            guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        }
        if #available(macOS 15.0, *) {
            if type == .microphone {
                guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
            }
        }
        
        // Already on writeQueue (the outputs' sampleHandlerQueue): no extra hop per sample
        do {
            guard let writer = self.assetWriter, writer.status == .writing else { return }
            
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isValid && (pts.flags.contains(.valid)) else { return }
            
            if !self.isWriterSessionStarted {
                // Critical: start session strictly on first valid video frame so audio doesn't pre-date video PTS
                if type == .screen {
                    writer.startSession(atSourceTime: pts)
                    self.isWriterSessionStarted = true
                    self.firstSampleTime = pts
                } else {
                    return
                }
            }
            
            guard pts >= self.firstSampleTime else { return }
            
            switch type {
            case .screen:
                if let input = self.videoWriterInput, input.isReadyForMoreMediaData {
                    if !input.append(sampleBuffer) {
                        NSLog("⚠️ Notchy: video append failed (status: %ld, error: %@)", writer.status.rawValue, String(describing: writer.error))
                    }
                }
            case .audio:
                if let input = self.audioWriterInput, input.isReadyForMoreMediaData {
                    if !input.append(sampleBuffer) {
                        NSLog("⚠️ Notchy: audio append failed (status: %ld, error: %@)", writer.status.rawValue, String(describing: writer.error))
                    }
                }
            default:
                if #available(macOS 15.0, *) {
                    if type == .microphone {
                        if let input = self.micWriterInput, input.isReadyForMoreMediaData {
                            if !input.append(sampleBuffer) {
                                NSLog("⚠️ Notchy: mic append failed (status: %ld, error: %@)", writer.status.rawValue, String(describing: writer.error))
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Timers
    
    private func startDurationTimer() {
        stopDurationTimer()
        recordingStartDate = Date()
        self.recordingDuration = 0.0
        self.recordingDurationText = "00:00"
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.recordingStartDate else { return }
            let elapsed = Date().timeIntervalSince(start)
            self.recordingDuration = elapsed
            let text = String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
            if text != self.recordingDurationText { self.recordingDurationText = text }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        durationTimer = timer
    }
    
    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
    
    private func startChunkRotationTimer() {
        stopChunkRotationTimer()
        // Rotate chunks every 30 seconds
        let timer = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.rotateReplayChunk()
        }
        timer.tolerance = 5.0 // no need to wake the CPU at an exact moment
        RunLoop.main.add(timer, forMode: .common)
        chunkTimer = timer
    }
    
    private func stopChunkRotationTimer() {
        chunkTimer?.invalidate()
        chunkTimer = nil
    }
    
    private func notifyUser(title: String, body: String) {
        NotificationService.shared.sendRecordingNotification(title: title, body: body)
    }
}

import Foundation
import AppKit
import SwiftUI
import Combine
import CoreAudio

public struct TrackInfo: Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var artwork: NSImage?
    public var isPlaying: Bool
    
    public init(title: String, artist: String, album: String = "", artwork: NSImage? = nil, isPlaying: Bool = true) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.isPlaying = isPlaying
    }
    
    public static func == (lhs: TrackInfo, rhs: TrackInfo) -> Bool {
        return lhs.title == rhs.title &&
               lhs.artist == rhs.artist &&
               lhs.album == rhs.album &&
               lhs.isPlaying == rhs.isPlaying &&
               lhs.artwork === rhs.artwork
    }
}

/// Playback position reference: the position at `reference` plus elapsed wall time while playing.
public struct TrackTimeline: Equatable {
    public var elapsed: Double
    public var duration: Double
    public var reference: Date
    public var rate: Double
    
    public func position(at date: Date) -> Double {
        let advanced = rate > 0 ? date.timeIntervalSince(reference) * rate : 0
        return min(duration, max(0, elapsed + advanced))
    }
}

public final class NowPlayingService: ObservableObject {
    public static let shared = NowPlayingService()
    
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentTrack: TrackInfo? = nil {
        didSet {
            lastAlbumSnapshot = currentTrack?.album
            if let track = currentTrack, track.isPlaying && oldValue?.title != track.title && !track.title.isEmpty {
                NotificationService.shared.sendMusicNotification(title: track.title, artist: track.artist, album: track.album)
            }
        }
    }
    
    /// Only available when the player reports duration (not for window-detected YouTube/browser audio).
    @Published public private(set) var timeline: TrackTimeline? = nil
    
    private let musicFilePath = AppPaths.ipcDir.appendingPathComponent("music.json").path
    private var lastMusicModDate: Date?
    
    // MediaRemote Function Pointers
    private typealias MRNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping (CFDictionary) -> Void) -> Void
    private typealias MRIsPlayingFunction = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias MRRegisterFunction = @convention(c) (DispatchQueue) -> Void
    
    private var mrGetInfo: MRNowPlayingInfoFunction?
    private var mrIsPlaying: MRIsPlayingFunction?
    private var mrRegister: MRRegisterFunction?
    
    private var pollTimer: Timer?
    private var isMockActive: Bool = false
    private var pauseDebounceTimer: Timer?
    private var lastUserActionTime: Date? = nil
    
    private init() {
        setupMediaRemote()
        setupDistributedNotifications()
        setupCoreAudioListener()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mediaServiceDidUpdate),
            name: NSNotification.Name("MediaArtworkServiceDidUpdateMedia"),
            object: nil
        )
    }
    
    @objc private func mediaServiceDidUpdate() {
        guard !isMockActive else { return }
        refreshAudioState()
    }
    
    /// Off while the Music tab is switched off: audio-device and player callbacks are then ignored too
    private var isEnabled = false
    
    public func start() {
        isEnabled = true
        startPolling()
        refreshAudioState()
    }
    
    public func stop() {
        isEnabled = false
        pollTimer?.invalidate()
        pollTimer = nil
        pauseDebounceTimer?.invalidate()
        pauseDebounceTimer = nil
        // The music wing must not keep showing the last track
        isPlaying = false
        currentTrack = nil
        timeline = nil
    }
    
    // MARK: - Playback Controls
    
    public func togglePlayPause() {
        let targetState = !isPlaying
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            self.isPlaying = targetState
            if var track = self.currentTrack {
                track.isPlaying = targetState
                self.currentTrack = track
            }
        }
        self.lastUserActionTime = Date()
        // Freeze/resume the progress bar immediately instead of waiting for the next poll
        if var t = timeline {
            let now = Date()
            t.elapsed = t.position(at: now)
            t.reference = now
            t.rate = targetState ? 1.0 : 0.0
            timeline = t
        }
        
        if isMockActive {
            return
        }
        
        dispatchPlayback(.togglePlayPause(play: targetState))
    }
    
    public func nextTrack() {
        if isMockActive { return }
        dispatchPlayback(.nextTrack)
        refreshSoonAfterSkip()
    }
    
    public func previousTrack() {
        if isMockActive { return }
        dispatchPlayback(.previousTrack)
        refreshSoonAfterSkip()
    }
    
    /// A skip changes the track, not the play state, so there is nothing to protect from stale polls:
    /// re-read quickly (the player needs a moment to switch) instead of waiting for the regular poll.
    private func refreshSoonAfterSkip() {
        for delay in [0.2, 0.5, 1.0, 1.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshAudioState()
            }
        }
    }
    
    /// MediaRemote's send returns true even when the system silently drops the command for non-entitled apps,
    /// so it can't tell us whether playback was controlled. Order: AuMusic UI, the player's own scripting
    /// (Music/Spotify, when it is the one playing), then the system media key, which reaches browsers and any other player.
    private func dispatchPlayback(_ command: PlaybackCommand) {
        if controlAuMusic(command: command) { return }
        
        let keyCode: Int32
        switch command {
        case .togglePlayPause: keyCode = 16
        case .nextTrack: keyCode = 17
        case .previousTrack: keyCode = 18
        }
        let isWebPlayer = currentTrack?.album == "YouTube" || (currentTrack?.artist.contains("YouTube") ?? false)
        if !AXIsProcessTrusted() && !askedAccessibility {
            // Posting the media key needs Accessibility; ask once per launch instead of on every press
            askedAccessibility = true
            PermissionManager.shared.requestAccessibility()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if !isWebPlayer && self.scriptPlayingNativePlayer(command) { return }
            Self.postSystemMediaKey(key: keyCode)
        }
    }
    
    /// Controls Music/Spotify through AppleScript, but only if that player is the one currently playing.
    private func scriptPlayingNativePlayer(_ command: PlaybackCommand) -> Bool {
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        let verb: String
        switch command {
        case .togglePlayPause(let play): verb = play ? "play" : "pause"
        case .nextTrack: verb = "next track"
        case .previousTrack: verb = "previous track"
        }
        for (bundleID, appName) in [("com.apple.Music", "Music"), ("com.spotify.client", "Spotify")] where running.contains(bundleID) {
            var error: NSDictionary?
            let state = NSAppleScript(source: "tell application \"\(appName)\" to return (player state as string)")?
                .executeAndReturnError(&error).stringValue ?? ""
            // Pausing/skipping only makes sense for the player that is playing; resume goes to the system key (last active player)
            guard state.contains("playing") else { continue }
            if NSAppleScript(source: "tell application \"\(appName)\" to \(verb)")?.executeAndReturnError(&error) != nil, error == nil {
                return true
            }
        }
        return false
    }
    
    private var askedAccessibility = false
    
    private enum PlaybackCommand {
        case togglePlayPause(play: Bool)
        case nextTrack
        case previousTrack
    }
    
    private func controlAuMusic(command: PlaybackCommand) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.bundleIdentifier ?? "").contains("AuMusic") || ($0.localizedName ?? "").contains("AuMusic")
        }) else { return false }
        
        let targetNames: [String]
        switch command {
        case .togglePlayPause(let play): targetNames = play ? ["Play"] : ["Pause"]
        case .nextTrack: targetNames = ["Forward"]
        case .previousTrack: targetNames = ["Back"]
        }
        
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsVal: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsVal) == .success,
              let windows = windowsVal as? [AXUIElement] else { return false }
        
        for w in windows {
            var foundBtn: AXUIElement?
            func scan(_ el: AXUIElement) {
                if foundBtn != nil { return }
                var descVal: AnyObject?
                AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descVal)
                if let desc = descVal as? String, targetNames.contains(desc) {
                    foundBtn = el
                    return
                }
                var childrenVal: AnyObject?
                if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenVal) == .success,
                   let children = childrenVal as? [AXUIElement] {
                    for c in children { scan(c) }
                }
            }
            scan(w)
            if let btn = foundBtn {
                let err = AXUIElementPerformAction(btn, kAXPressAction as CFString)
                if err == .success {
                    return true
                }
            }
        }
        return false
    }
    
    public static func postSystemMediaKey(key: Int32) {
        func post(down: Bool) {
            let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xa00) : .init(rawValue: 0xb00)
            let data1 = Int((key << 16) | (down ? 0xa00 : 0xb00))
            let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }
    
    // MARK: - CoreAudio Hardware Detection
    
    public func isSystemAudioPlaying() -> Bool {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID
        )
        guard status == noErr, defaultOutputDeviceID != 0 else { return false }
        
        var isRunning: UInt32 = 0
        var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
        var isRunningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let isRunningStatus = AudioObjectGetPropertyData(
            defaultOutputDeviceID,
            &isRunningAddress,
            0,
            nil,
            &isRunningSize,
            &isRunning
        )
        return isRunningStatus == noErr && isRunning != 0
    }
    
    private func setupCoreAudioListener() {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID
        )
        guard status == noErr, defaultOutputDeviceID != 0 else { return }
        
        var isRunningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectAddPropertyListenerBlock(
            defaultOutputDeviceID,
            &isRunningAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.refreshAudioState()
        }
    }
    
    // MARK: - MediaRemote Integration
    
    private func setupMediaRemote() {
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")) else {
            return
        }
        
        if let getInfoPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            mrGetInfo = unsafeBitCast(getInfoPtr, to: MRNowPlayingInfoFunction.self)
        }
        if let isPlayingPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString) {
            mrIsPlaying = unsafeBitCast(isPlayingPtr, to: MRIsPlayingFunction.self)
        }
        if let registerPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
            mrRegister = unsafeBitCast(registerPtr, to: MRRegisterFunction.self)
            mrRegister?(DispatchQueue.main)
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mediaRemoteDidChange),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mediaRemoteDidChange),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            object: nil
        )
    }
    
    @objc private func mediaRemoteDidChange() {
        guard !isMockActive else { return }
        refreshAudioState()
    }
    
    // MARK: - Distributed Notifications (Apple Music & Spotify)
    
    private var lastDistributedTrack: TrackInfo?
    private var lastFetchedMediaKey: String?
    private var lastArtwork: NSImage?
    
    private func setupDistributedNotifications() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            self,
            selector: #selector(playerNotificationReceived(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
        dnc.addObserver(
            self,
            selector: #selector(playerNotificationReceived(_:)),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )
    }
    
    @objc private func playerNotificationReceived(_ notification: Notification) {
        guard !isMockActive, isEnabled else { return }
        
        if let userInfo = notification.userInfo {
            let name = (userInfo["Name"] as? String) ?? (userInfo["track"] as? String)
            let artist = (userInfo["Artist"] as? String) ?? (userInfo["artist"] as? String)
            let album = (userInfo["Album"] as? String) ?? (userInfo["album"] as? String) ?? ""
            let state = (userInfo["Player State"] as? String) ?? (userInfo["player_state"] as? String)
            
            if let name = name, !name.isEmpty, state == "Playing" || state == "kPlayerStatePlaying" {
                let art = lastArtwork
                lastDistributedTrack = TrackInfo(title: name, artist: artist ?? "", album: album, artwork: art, isPlaying: true)
                
                // Fetch high-res iTunes artwork
                self.artworkWanted = name
                MediaArtworkService.shared.fetchMusicArtwork(query: "\(artist ?? "") \(name)") { [weak self] downloaded in
                    guard let self = self, let downloaded = downloaded else { return }
                    guard self.artworkWanted == name else { return }
                    self.lastArtwork = downloaded
                    if self.currentTrack?.title == name {
                        self.currentTrack?.artwork = downloaded
                    }
                }
            }
        }
        
        refreshAudioState()
    }
    
    // MARK: - Active Media App Detection (YouTube / QuickTime / Browsers)
    
    /// Players the notch may name when it has no track metadata. Browsers are left out on purpose: a browser tab
    /// is not a player, and naming whichever browser happens to be open was wrong when music came from elsewhere.
    private static var knownPlayers: [(hint: String, name: String, artist: String)] { [
        ("com.apple.music", "Apple Music", tr("Музыка", "Music")),
        ("com.spotify.client", "Spotify", tr("Музыка", "Music")),
        ("com.apple.quicktimeplayerx", "QuickTime Player", tr("Видео / Аудио", "Video / Audio")),
        ("com.colliderli.iina", "IINA Player", tr("Медиаплеер", "Media player")),
        ("org.videolan.vlc", "VLC Media Player", tr("Медиаплеер", "Media player")),
        ("aumusic", "", tr("Музыка", "Music")), ("yandex", "", tr("Музыка", "Music")), ("tidal", "", tr("Музыка", "Music")),
        ("deezer", "", tr("Музыка", "Music")), ("vox", "", tr("Музыка", "Music")), ("swinsian", "", tr("Музыка", "Music")),
        ("doppler", "", tr("Музыка", "Music")), ("soundcloud", "", tr("Музыка", "Music")),
    ] }

    /// The player that is actually sending audio out right now, or nil when only non-players (browsers, Discord…) are.
    private func detectActiveMediaApp() -> (name: String, artist: String, icon: NSImage?)? {
        let running = NSWorkspace.shared.runningApplications
        func match(_ bundleID: String) -> (name: String, artist: String, icon: NSImage?)? {
            let bid = bundleID.lowercased()
            guard let player = Self.knownPlayers.first(where: { bid.contains($0.hint) }) else { return nil }
            let app = running.first { $0.bundleIdentifier?.lowercased() == bid }
            return (player.name.isEmpty ? (app?.localizedName ?? bundleID) : player.name, player.artist, app?.icon)
        }
        if #available(macOS 14.2, *) {
            return Self.audioOutputBundleIDs().lazy.compactMap(match).first
        }
        // shortcut: before macOS 14.2 there is no per-process audio state, so guess from the running players.
        return running.lazy.compactMap { $0.bundleIdentifier }.compactMap(match).first
    }

    @available(macOS 14.2, *)
    private static func audioOutputBundleIDs() -> [String] {
        func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
        var listAddr = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { p in
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            var runAddr = addr(kAudioProcessPropertyIsRunningOutput)
            guard AudioObjectGetPropertyData(p, &runAddr, 0, nil, &runSize, &running) == noErr, running == 1 else { return nil }
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddr = addr(kAudioProcessPropertyBundleID)
            guard AudioObjectGetPropertyData(p, &bundleAddr, 0, nil, &bundleSize, &bundle) == noErr,
                  let id = bundle?.takeRetainedValue() as String?, !id.isEmpty else { return nil }
            return id
        }
    }

    /// No player is making sound: show the current track as paused instead of inventing one.
    private func markNotPlaying() {
        if isPlaying { isPlaying = false }
        if var current = currentTrack, current.isPlaying {
            current.isPlaying = false
            currentTrack = current
        }
    }
    
    // MARK: - Refresh State
    
    /// Title whose artwork was requested last: a slow answer for a track already skipped must not overwrite the current cover.
    private var artworkWanted = ""
    
    private func startPolling() {
        pollTimer?.invalidate()
        // 1 s while something plays (fast track-change reaction); 3 s otherwise, nothing to follow
        var tick = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            tick += 1
            self.checkMockFile()
            if !self.isMockActive && (self.isPlaying || tick % 3 == 0) {
                self.refreshAudioState()
            }
        }
    }
    
    /// Reads AuMusic's player bar through Accessibility: elapsed time is a static text, remaining time is the
    /// "-mm:ss" button right after it, and the Pause/Play button tells whether it is playing.
    private func readAuMusicTimeline() -> TrackTimeline? {
        guard AXIsProcessTrusted(), let app = MediaArtworkService.shared.auMusicApplication() else { return nil }
        
        func attr(_ el: AXUIElement, _ key: String) -> String? {
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success else { return nil }
            return v as? String
        }
        func seconds(_ text: String) -> Double? {
            let parts = text.split(separator: ":").compactMap { Double($0) }
            guard (2...3).contains(parts.count), text.split(separator: ":").count == parts.count else { return nil }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        func children(_ el: AXUIElement) -> [AXUIElement] {
            var v: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v)
            return (v as? [AXUIElement]) ?? []
        }
        
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsVal: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsVal) == .success,
              let windows = windowsVal as? [AXUIElement] else { return nil }
        
        for window in windows {
            for container in children(window) {
                let items = children(container)
                var playing = false
                for (i, item) in items.enumerated() {
                    let desc = attr(item, kAXDescriptionAttribute as String) ?? ""
                    if desc == "Pause" { playing = true }
                    guard desc.hasPrefix("-"), i > 0,
                          let remaining = seconds(String(desc.dropFirst())),
                          let elapsedText = attr(items[i - 1], kAXValueAttribute as String),
                          let elapsed = seconds(elapsedText) else { continue }
                    // Pause/Play sits earlier in the same row; scan again so the order doesn't matter
                    playing = playing || items.contains { attr($0, kAXDescriptionAttribute as String) == "Pause" }
                    return TrackTimeline(elapsed: elapsed, duration: elapsed + remaining, reference: Date(), rate: playing ? 1.0 : 0.0)
                }
            }
        }
        return nil
    }
    
    /// Republishes only when the projected position drifts or the track/rate changes, so polling doesn't churn the UI.
    private func applyTimeline(_ new: TrackTimeline?) {
        guard let new = new else {
            if timeline != nil { timeline = nil }
            return
        }
        let now = Date()
        if let old = timeline, old.duration == new.duration, old.rate == new.rate,
           abs(old.position(at: now) - new.position(at: now)) < 1.5 {
            return
        }
        timeline = new
    }
    
    private let pollQueue = DispatchQueue(label: "com.local.notchy.nowplaying.poll", qos: .utility)
    private let refreshLock = NSLock()
    private var refreshQueued = false
    /// Album of the current track, readable off the main thread (the poll runs on `pollQueue`).
    private var lastAlbumSnapshot: String?
    
    /// The poll does Accessibility IPC, CoreAudio and window-list work; it must never run on the main thread.
    /// Requests arriving while one is already queued are coalesced into it.
    public func refreshAudioState() {
        guard isEnabled else { return }
        refreshLock.lock()
        if refreshQueued { refreshLock.unlock(); return }
        refreshQueued = true
        refreshLock.unlock()
        pollQueue.async { [weak self] in
            guard let self = self else { return }
            self.refreshLock.lock()
            self.refreshQueued = false
            self.refreshLock.unlock()
            self.performRefresh()
        }
    }
    
    private func performRefresh() {
        guard !isMockActive else { return }
        
        let coreAudioPlaying = isSystemAudioPlaying()
        let lastAlbum = lastAlbumSnapshot
        // Performance optimization: only scan window lists if audio is actively playing through CoreAudio
        let detectedMedia = coreAudioPlaying ? MediaArtworkService.shared.detectMediaFromWindows() : nil
        
        if let mrGetInfo = mrGetInfo {
            let queue = DispatchQueue.global(qos: .utility)
            mrGetInfo(queue) { [weak self] dict in
                guard let self = self, !self.isMockActive else { return }
                let d = dict as? [String: Any] ?? [:]
                
                let title = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String
                let artist = d["kMRMediaRemoteNowPlayingInfoArtist"] as? String
                let album = d["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
                
                var artworkImg: NSImage?
                if let artworkData = d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
                    artworkImg = NSImage(data: artworkData)
                }
                
                let playbackRate = (d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double) ?? 0.0
                let mediaRemotePlaying = playbackRate > 0.0
                let isYouTubePlaying = coreAudioPlaying && (detectedMedia?.source == .youtube)
                let hasTrackMetadata = (title != nil && !(title!.isEmpty))
                let duration = (d["kMRMediaRemoteNowPlayingInfoDuration"] as? Double) ?? 0
                let elapsed = (d["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double) ?? 0
                let stamp = (d["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date) ?? Date()
                var reportedTimeline: TrackTimeline? = (hasTrackMetadata && duration > 0 && !isYouTubePlaying)
                    ? TrackTimeline(elapsed: elapsed, duration: duration, reference: stamp, rate: playbackRate)
                    : nil
                // MediaRemote gives nothing to unentitled apps; AuMusic shows its own position in its UI. While paused
                // nothing is "detected", so the playlist album tag set for AuMusic tracks keeps the bar alive.
                if reportedTimeline == nil && !isYouTubePlaying {
                    var isAuMusic = lastAlbum == "Плейлист" && !coreAudioPlaying
                    if case .genericAudio(let name)? = detectedMedia?.source, name.contains("AuMusic") { isAuMusic = true }
                    if isAuMusic { reportedTimeline = self.readAuMusicTimeline() }
                }
                let isPlayingNow = isYouTubePlaying || (hasTrackMetadata ? mediaRemotePlaying : (coreAudioPlaying || mediaRemotePlaying))
                
                DispatchQueue.main.async {
                    if let lastAction = self.lastUserActionTime, Date().timeIntervalSince(lastAction) < 1.2 {
                        return
                    }
                    self.applyTimeline(reportedTimeline)
                    
                    if isPlayingNow {
                        self.pauseDebounceTimer?.invalidate()
                        self.pauseDebounceTimer = nil
                        
                        let trackTitle: String
                        let trackArtist: String
                        let trackAlbum: String
                        var trackArtwork: NSImage?
                        
                        // PRIORITY 1: Window-detected YouTube video (Thumbnail + Channel/Artist)
                        if let media = detectedMedia, media.source == .youtube {
                            trackTitle = media.title
                            trackArtist = media.artist
                            trackAlbum = "YouTube"
                            
                            let key = media.rawQuery
                            if key == self.lastFetchedMediaKey, let cached = self.lastArtwork {
                                trackArtwork = cached
                            } else {
                                self.lastFetchedMediaKey = key
                                // Immediately show sleek YouTube red card (NEVER generic Safari/Chrome icon)
                                trackArtwork = MediaArtworkService.shared.placeholderArtwork(for: .youtube)
                                self.lastArtwork = trackArtwork
                                
                                // Fetch real preview thumbnail asynchronously
                                self.artworkWanted = media.title
                                MediaArtworkService.shared.fetchArtwork(for: media) { [weak self] downloaded in
                                    guard let self = self, let downloaded = downloaded else { return }
                                    guard self.artworkWanted == media.title else { return }
                                    self.lastArtwork = downloaded
                                    if var current = self.currentTrack, current.title == media.title {
                                        current.artwork = downloaded
                                        self.currentTrack = current
                                    }
                                }
                            }
                        }
                        // PRIORITY 2: Apple Music / Spotify with metadata from MediaRemote or DistributedNotification
                        else if let t = title, !t.isEmpty {
                            trackTitle = t
                            trackArtist = artist ?? ""
                            trackAlbum = album
                            trackArtwork = artworkImg ?? self.lastArtwork
                            
                            if artworkImg == nil && self.lastFetchedMediaKey != t {
                                self.lastFetchedMediaKey = t
                                self.artworkWanted = t
                                MediaArtworkService.shared.fetchMusicArtwork(query: "\(trackArtist) \(trackTitle)") { [weak self] downloaded in
                                    guard let self = self, let downloaded = downloaded else { return }
                                    guard self.artworkWanted == t else { return }
                                    self.lastArtwork = downloaded
                                    if var current = self.currentTrack, current.title == t {
                                        current.artwork = downloaded
                                        self.currentTrack = current
                                    }
                                }
                            }
                        }
                        // PRIORITY 3: DistributedNotification track (Apple Music / Spotify)
                        else if let dist = self.lastDistributedTrack, coreAudioPlaying {
                            trackTitle = dist.title
                            trackArtist = dist.artist
                            trackAlbum = dist.album
                            trackArtwork = self.lastArtwork ?? MediaArtworkService.shared.placeholderArtwork(for: .appleMusic)
                        }
                        // PRIORITY 4: QuickTime or AuMusic window
                        else if let media = detectedMedia {
                            trackTitle = media.title
                            trackArtist = media.artist
                            trackAlbum = media.album
                            
                            let key = "\(media.source)_\(media.artist)_\(media.title)"
                            if let direct = media.directArtwork {
                                self.lastFetchedMediaKey = key
                                self.lastArtwork = direct
                                trackArtwork = direct
                            } else if key == self.lastFetchedMediaKey, let cached = self.lastArtwork {
                                trackArtwork = cached
                            } else {
                                self.lastFetchedMediaKey = key
                                self.lastArtwork = nil
                                trackArtwork = MediaArtworkService.shared.placeholderArtwork(for: media.source)
                                
                                self.artworkWanted = media.title
                                
                                MediaArtworkService.shared.fetchArtwork(for: media) { [weak self] downloaded in
                                    guard let self = self, let downloaded = downloaded else { return }
                                    guard self.artworkWanted == media.title else { return }
                                    self.lastArtwork = downloaded
                                    if var current = self.currentTrack, current.title == media.title {
                                        current.artwork = downloaded
                                        self.currentTrack = current
                                    }
                                }
                            }
                        }
                        // PRIORITY 5: Fallback to detected active audio app
                        else {
                            guard let appMeta = self.detectActiveMediaApp() else { self.markNotPlaying(); return }
                            trackTitle = appMeta.name
                            trackArtist = appMeta.artist
                            trackAlbum = ""
                            trackArtwork = MediaArtworkService.shared.placeholderArtwork(for: .genericAudio(appMeta.name))
                        }
                        
                        let newTrack = TrackInfo(
                            title: trackTitle,
                            artist: trackArtist,
                            album: trackAlbum,
                            artwork: trackArtwork,
                            isPlaying: true
                        )
                        if !self.isPlaying { self.isPlaying = true }
                        if self.currentTrack != newTrack {
                            self.currentTrack = newTrack
                        }
                    } else {
                        // Paused state: retain track info, but cleanly set isPlaying to false
                        self.pauseDebounceTimer?.invalidate()
                        self.pauseDebounceTimer = nil
                        if self.isPlaying { self.isPlaying = false }
                        if var current = self.currentTrack {
                            if current.isPlaying {
                                current.isPlaying = false
                                self.currentTrack = current
                            }
                        } else if let t = title, !t.isEmpty {
                            let pausedTrack = TrackInfo(
                                title: t,
                                artist: artist ?? "",
                                album: album,
                                artwork: artworkImg ?? self.lastArtwork,
                                isPlaying: false
                            )
                            if self.currentTrack != pausedTrack {
                                self.currentTrack = pausedTrack
                            }
                        } else if let media = detectedMedia {
                            let placeholder = MediaArtworkService.shared.placeholderArtwork(for: media.source)
                            let pausedTrack = TrackInfo(
                                title: media.title,
                                artist: media.artist,
                                album: media.album,
                                artwork: self.lastArtwork ?? media.directArtwork ?? placeholder,
                                isPlaying: false
                            )
                            if self.currentTrack != pausedTrack {
                                self.currentTrack = pausedTrack
                            }
                        }
                    }
                }
            }
        } else {
            DispatchQueue.main.async {
                if coreAudioPlaying {
                    self.pauseDebounceTimer?.invalidate()
                    self.pauseDebounceTimer = nil
                    
                    if let media = detectedMedia, media.source == .youtube {
                        let placeholder = MediaArtworkService.shared.placeholderArtwork(for: .youtube)
                        self.isPlaying = true
                        self.currentTrack = TrackInfo(title: media.title, artist: media.artist, album: "YouTube", artwork: self.lastArtwork ?? placeholder, isPlaying: true)
                        
                        self.artworkWanted = media.title
                        
                        MediaArtworkService.shared.fetchArtwork(for: media) { [weak self] downloaded in
                            guard let self = self, let downloaded = downloaded else { return }
                            guard self.artworkWanted == media.title else { return }
                            self.lastArtwork = downloaded
                            if var current = self.currentTrack, current.title == media.title {
                                current.artwork = downloaded
                                self.currentTrack = current
                            }
                        }
                    } else if let media = detectedMedia {
                        self.isPlaying = true
                        let placeholder = MediaArtworkService.shared.placeholderArtwork(for: media.source)
                        let art = media.directArtwork ?? self.lastArtwork ?? placeholder
                        if let direct = media.directArtwork {
                            self.lastArtwork = direct
                        }
                        self.currentTrack = TrackInfo(title: media.title, artist: media.artist, album: media.album, artwork: art, isPlaying: true)
                        
                        if media.directArtwork == nil {
                            self.artworkWanted = media.title
                            MediaArtworkService.shared.fetchArtwork(for: media) { [weak self] downloaded in
                                guard let self = self, let downloaded = downloaded else { return }
                                guard self.artworkWanted == media.title else { return }
                                self.lastArtwork = downloaded
                                if var current = self.currentTrack, current.title == media.title {
                                    current.artwork = downloaded
                                    self.currentTrack = current
                                }
                            }
                        }
                    } else if let appMeta = self.detectActiveMediaApp() {
                        self.isPlaying = true
                        self.currentTrack = TrackInfo(title: appMeta.name, artist: appMeta.artist, artwork: MediaArtworkService.shared.placeholderArtwork(for: .genericAudio(appMeta.name)), isPlaying: true)
                    } else {
                        self.markNotPlaying()
                    }
                } else {
                    if self.isPlaying && self.pauseDebounceTimer == nil {
                        self.pauseDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                            defer { self?.pauseDebounceTimer = nil }
                            guard let self = self, !self.isSystemAudioPlaying() else { return }
                            self.isPlaying = false
                            if var current = self.currentTrack {
                                current.isPlaying = false
                                self.currentTrack = current
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Mock Support
    
    public func setMockTrack(title: String, artist: String, album: String = "", artworkPath: String? = nil, playing: Bool = true) {
        var img: NSImage? = nil
        if let path = artworkPath, !path.isEmpty {
            img = NSImage(contentsOfFile: path)
        }
        
        DispatchQueue.main.async {
            self.isMockActive = true
            self.timeline = nil
            self.isPlaying = playing
            self.currentTrack = TrackInfo(title: title, artist: artist, album: album, artwork: img, isPlaying: playing)
        }
    }
    
    public func clearMock() {
        DispatchQueue.main.async {
            self.isMockActive = false
        }
        refreshAudioState()
    }
    
    private func checkMockFile() {
        guard FileManager.default.fileExists(atPath: musicFilePath),
              let attrs = try? FileManager.default.attributesOfItem(atPath: musicFilePath),
              let modDate = attrs[.modificationDate] as? Date else {
            return
        }
        
        if lastMusicModDate == nil {
            // A leftover mock file from a previous run must not override real playback at launch
            lastMusicModDate = modDate
            return
        }
        if modDate > lastMusicModDate! {
            lastMusicModDate = modDate
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: musicFilePath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            
            let action = json["action"] as? String ?? ""
            if action == "quit" || action == "terminate" {
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
                return
            }
            if action == "clear" || action == "reset" {
                clearMock()
                return
            }
            
            let playing = (json["playing"] as? Bool) ?? (json["isPlaying"] as? Bool) ?? true
            let title = (json["title"] as? String) ?? "Music Track"
            let artist = (json["artist"] as? String) ?? "Artist"
            let album = (json["album"] as? String) ?? ""
            let artworkPath = json["artwork_path"] as? String
            
            setMockTrack(title: title, artist: artist, album: album, artworkPath: artworkPath, playing: playing)
        }
    }
}

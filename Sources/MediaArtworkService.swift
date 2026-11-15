import Foundation
import AppKit
import CoreGraphics
import AVFoundation

public struct DetectedMediaInfo: Equatable {
    public let title: String
    public let artist: String
    public let album: String
    public let rawQuery: String
    public let source: MediaSourceType
    public let videoId: String?
    public let directArtwork: NSImage?
    
    public init(
        title: String,
        artist: String,
        album: String = "",
        rawQuery: String = "",
        source: MediaSourceType,
        videoId: String? = nil,
        directArtwork: NSImage? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.rawQuery = rawQuery
        self.source = source
        self.videoId = videoId
        self.directArtwork = directArtwork
    }
    
    public static func == (lhs: DetectedMediaInfo, rhs: DetectedMediaInfo) -> Bool {
        return lhs.title == rhs.title &&
               lhs.artist == rhs.artist &&
               lhs.album == rhs.album &&
               lhs.rawQuery == rhs.rawQuery &&
               lhs.source == rhs.source &&
               lhs.videoId == rhs.videoId &&
               lhs.directArtwork === rhs.directArtwork
    }
}

public enum MediaSourceType: Equatable {
    case youtube
    case appleMusic
    case spotify
    case quickTime
    case webBrowser(String)
    case genericAudio(String)
}

public final class MediaArtworkService {
    public static let shared = MediaArtworkService()
    
    // RAM cache
    private let memoryCache = NSCache<NSString, NSImage>()
    
    // Disk cache directory
    private let diskCacheURL: URL = {
        let url = AppPaths.cacheDir.appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    
    // Deduplication of ongoing network requests
    private var activeRequests: [String: [(NSImage?) -> Void]] = [:]
    private let requestLock = NSLock()
    
    private init() {
        memoryCache.countLimit = 60
    }
    
    // MARK: - Detect Media From Windows (Zero TCC / Zero Permissions)
    
    private var lastActiveYouTubeMedia: DetectedMediaInfo?
    
    public func clearRetainedMedia() {
        lastActiveYouTubeMedia = nil
    }
    
    private func isAppRunning(name: String) -> Bool {
        return NSWorkspace.shared.runningApplications.contains { app in
            (app.localizedName?.localizedCaseInsensitiveContains(name) == true) ||
            (app.bundleIdentifier?.localizedCaseInsensitiveContains(name) == true)
        }
    }
    
    public func detectMediaFromWindows() -> DetectedMediaInfo? {
        guard PermissionManager.shared.isScreenCaptureGranted else { return nil }
        let windowList = CGWindowListCopyWindowInfo(.excludeDesktopElements, kCGNullWindowID) as? [[String: Any]] ?? []
        
        let browserNames: Set<String> = [
            "Safari", "Google Chrome", "Arc", "Brave Browser", "Firefox",
            "Opera", "Microsoft Edge", "Vivaldi", "Zen", "Chromium", "WebKit"
        ]
        
        // Priority 1: Check for visible or active YouTube windows
        for w in windowList {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let name = w[kCGWindowName as String] as? String ?? ""
            
            guard !name.isEmpty else { continue }
            let isBrowser = browserNames.contains(owner) || owner.contains("Safari") || owner.contains("Chrome")
            
            if isBrowser && (name.contains("YouTube") || name.contains("youtu.be")) {
                var clean = name
                // Remove notification counters: (1), [2], ▶, etc.
                clean = clean.replacingOccurrences(of: #"^\s*[\(\[]\d+[\)\]]\s*"#, with: "", options: .regularExpression)
                clean = clean.replacingOccurrences(of: #"^[▶►\s]+"#, with: "", options: .regularExpression)
                
                // Remove browser and site suffixes with any dash type (- – — | •)
                clean = clean.replacingOccurrences(of: #"\s*[-–—|•]\s*YouTube.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                clean = clean.replacingOccurrences(of: #"\s*[-–—|•]\s*Google Chrome.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                clean = clean.replacingOccurrences(of: #"\s*[-–—|•]\s*Safari.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                clean = clean.replacingOccurrences(of: #"\s*[-–—|•]\s*Arc.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                clean = clean.replacingOccurrences(of: #"\s*[-–—|•]\s*Brave.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
                
                var artist = "YouTube"
                var trackTitle = clean
                
                if let dashRange = clean.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) {
                    let a = String(clean[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let t = String(clean[dashRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !a.isEmpty && !t.isEmpty {
                        artist = a
                        trackTitle = t
                    }
                }
                
                // Extract video ID if present in the title
                var videoId: String? = nil
                if let match = name.range(of: #"(?:v=|\/vi\/|youtu\.be\/|\/v\/)([a-zA-Z0-9_-]{11})"#, options: .regularExpression) {
                    let sub = String(name[match])
                    let comps = sub.components(separatedBy: CharacterSet(charactersIn: "=/"))
                    videoId = comps.last
                }
                
                let detected = DetectedMediaInfo(
                    title: trackTitle.isEmpty ? "YouTube Video" : trackTitle,
                    artist: artist.isEmpty ? "YouTube" : artist,
                    album: "YouTube",
                    rawQuery: clean,
                    source: .youtube,
                    videoId: videoId
                )
                self.lastActiveYouTubeMedia = detected
                return detected
            }
        }
        
        // Priority 1.5: If user switched tabs in the browser, retain the active YouTube video while audio plays
        // (not when AuMusic has a window: its audio would be mistaken for the stale video)
        // Matched by process (bundle id), not window owner name: the app was renamed (AuMusic -> KAIVO)
        let auPID = auMusicApplication()?.processIdentifier
        let auMusicOpen = auPID != nil && windowList.contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == auPID }
        if let retained = self.lastActiveYouTubeMedia, !auMusicOpen,
           NowPlayingService.shared.isSystemAudioPlaying(),
           (isAppRunning(name: "Safari") || isAppRunning(name: "Chrome") || isAppRunning(name: "Arc") || isAppRunning(name: "Brave")) {
            return retained
        }
        
        // Priority 2: QuickTime Player
        for w in windowList {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let name = w[kCGWindowName as String] as? String ?? ""
            if owner.contains("QuickTime") && !name.isEmpty && name != "QuickTime Player" {
                var trackTitle = name
                var trackArtist = "QuickTime Player"
                
                let pid = (w[kCGWindowOwnerPID as String] as? pid_t) ??
                    NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.QuickTimePlayerX" })?.processIdentifier ?? 0
                if pid > 0, let fileURL = findOpenAudioFile(forPID: pid) {
                    let ext = extractMetadataAndArtwork(from: fileURL)
                    if let t = ext.title, !t.isEmpty { trackTitle = t }
                    if let a = ext.artist, !a.isEmpty { trackArtist = a }
                    if let img = ext.image {
                        let detected = DetectedMediaInfo(
                            title: trackTitle,
                            artist: trackArtist,
                            album: "Видео",
                            rawQuery: "\(trackArtist) \(trackTitle)",
                            source: .quickTime,
                            videoId: nil
                        )
                        self.memoryCache.setObject(img, forKey: cacheKeyForMedia(detected) as NSString)
                        return detected
                    }
                }
                
                return DetectedMediaInfo(
                    title: trackTitle,
                    artist: trackArtist,
                    album: "Видео",
                    rawQuery: "\(trackArtist) \(trackTitle)",
                    source: .quickTime,
                    videoId: nil
                )
            }
        }
        
        // Priority 3: AuMusic
        for w in windowList {
            let name = w[kCGWindowName as String] as? String ?? ""
            if let pid = auPID, (w[kCGWindowOwnerPID as String] as? pid_t) == pid {
                
                var trackTitle = "AuMusic"
                var trackArtist = "AuMusic"
                var directImage: NSImage? = nil
                
                // 1. Try finding open audio file (e.g. Katy Perry - Firework.flac).
                // lsof + tag/cover decoding is expensive (a process spawn and a JPEG decode), so the result is
                // cached and only recomputed when the track shown by AuMusic's UI changes.
                if pid > 0 {
                    let uiTitle = readAuMusicTrackMeta()?.title
                    if let c = auFileCache, c.pid == pid, c.uiTitle == uiTitle,
                       Date().timeIntervalSince(c.time) < (uiTitle == nil ? 5.0 : 120.0) {
                        trackTitle = c.title ?? trackTitle
                        trackArtist = c.artist ?? trackArtist
                        directImage = c.image
                    } else {
                        var cached = AuFileCache(pid: pid, uiTitle: uiTitle, time: Date(), title: nil, artist: nil, image: nil)
                        if let audioURL = findOpenAudioFile(forPID: pid) {
                            let ext = extractMetadataAndArtwork(from: audioURL)
                            if let t = ext.title, !t.isEmpty { trackTitle = t; cached.title = t }
                            if let a = ext.artist, !a.isEmpty { trackArtist = a; cached.artist = a }
                            directImage = ext.image
                            cached.image = ext.image
                        }
                        auFileCache = cached
                    }
                }
                
                // 2. Fallback to preferences or window name
                if trackTitle == "AuMusic" {
                    let meta = readAuMusicTrackMeta()
                    if let t = meta?.title { trackTitle = t }
                    if let a = meta?.artist { trackArtist = a }
                    if trackTitle == "AuMusic" && !name.isEmpty && name != "AuMusic" {
                        trackTitle = name
                    }
                }
                
                let detected = DetectedMediaInfo(
                    title: trackTitle,
                    artist: trackArtist,
                    album: "Плейлист",
                    rawQuery: "\(trackArtist) \(trackTitle)",
                    source: .genericAudio("AuMusic"),
                    videoId: nil,
                    directArtwork: directImage
                )
                
                if let direct = directImage {
                    let key = cacheKeyForMedia(detected)
                    self.memoryCache.setObject(direct, forKey: key as NSString)
                }
                
                return detected
            }
        }
        
        return nil
    }
    
    // MARK: - Open Media File Inspector (lsof + AVFoundation)
    
    public static func decodeLsofPath(_ path: String) -> String {
        var bytes = [UInt8]()
        let chars = Array(path.utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == UInt8(ascii: "\\") && i + 3 < chars.count && chars[i + 1] == UInt8(ascii: "x") {
                let h1 = chars[i + 2]
                let h2 = chars[i + 3]
                func hexVal(_ c: UInt8) -> UInt8? {
                    switch c {
                    case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
                    case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
                    case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
                    default: return nil
                    }
                }
                if let v1 = hexVal(h1), let v2 = hexVal(h2) {
                    bytes.append((v1 << 4) | v2)
                    i += 4
                    continue
                }
            }
            bytes.append(chars[i])
            i += 1
        }
        return String(bytes: bytes, encoding: .utf8) ?? path
    }
    
    private struct AuFileCache {
        var pid: pid_t
        var uiTitle: String?
        var time: Date
        var title: String?
        var artist: String?
        var image: NSImage?
    }
    private var auFileCache: AuFileCache?
    
    public func findOpenAudioFile(forPID pid: pid_t) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-p", "\(pid)", "-Fn"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            
            let audioExts: Set<String> = ["mp3", "m4a", "flac", "wav", "aac", "ogg", "alac", "opus", "aiff", "mp4", "mov", "mkv"]
            for line in output.components(separatedBy: "\n") {
                guard line.hasPrefix("n/") else { continue }
                let rawPath = String(line.dropFirst())
                let decoded = Self.decodeLsofPath(rawPath)
                let url = URL(fileURLWithPath: decoded)
                if audioExts.contains(url.pathExtension.lowercased()) {
                    return url
                }
            }
        } catch {
            return nil
        }
        return nil
    }
    
    public func extractMetadataAndArtwork(from fileURL: URL) -> (image: NSImage?, title: String?, artist: String?) {
        let asset = AVAsset(url: fileURL)
        var image: NSImage?
        var title: String?
        var artist: String?
        
        // Check commonMetadata
        for item in asset.commonMetadata {
            if item.commonKey == .commonKeyArtwork, let data = item.dataValue {
                image = NSImage(data: data)
            } else if item.commonKey == .commonKeyTitle, let str = item.stringValue {
                title = str
            } else if item.commonKey == .commonKeyArtist, let str = item.stringValue {
                artist = str
            }
        }
        
        // Also check all metadata for MP3 (APIC), MP4 (covr), and FLAC (METADATA_BLOCK_PICTURE)
        if image == nil {
            for item in asset.metadata {
                let keyStr = (item.key as? String) ?? item.commonKey?.rawValue ?? ""
                if keyStr.contains("artwork") || keyStr == "covr" || keyStr == "METADATA_BLOCK_PICTURE" || keyStr == "PICTURE" {
                    if let data = item.dataValue, let img = NSImage(data: data) {
                        image = img
                        break
                    }
                }
            }
        }
        
        // If title/artist not in metadata, parse the filename: "Artist - Title"
        let base = Self.decodeLsofPath(fileURL.deletingPathExtension().lastPathComponent)
        if (title == nil || title?.isEmpty == true) || (artist == nil || artist?.isEmpty == true) {
            if let dash = base.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) {
                let a = String(base[..<dash.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let t = String(base[dash.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !a.isEmpty { artist = a }
                if !t.isEmpty { title = t }
            } else {
                if title == nil || title?.isEmpty == true { title = base }
            }
        }
        
        return (image, title, artist)
    }
    
    // MARK: - AuMusic Container & Accessibility Integration
    
    private var auApp: NSRunningApplication?
    
    /// AuMusic's process. `localizedName` is an expensive lookup, so match by bundle id and keep the result.
    public func auMusicApplication() -> NSRunningApplication? {
        if let app = auApp, !app.isTerminated { return app }
        auApp = NSWorkspace.shared.runningApplications.first { ($0.bundleIdentifier ?? "").contains("AuMusic") }
        return auApp
    }
    
    /// Fast path: the player bar is a flat list in the window's hosting view where the "Title, Artist" button
    /// sits right before the "Back" button. Reading these few siblings costs a handful of AX calls instead of
    /// walking the whole UI tree (playlists and rows included).
    private func readAuMusicTrackFromPlayerBar(_ app: NSRunningApplication) -> (title: String, artist: String)? {
        func desc(_ el: AXUIElement) -> String? {
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &v) == .success else { return nil }
            return v as? String
        }
        func children(_ el: AXUIElement) -> [AXUIElement] {
            var v: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v)
            return (v as? [AXUIElement]) ?? []
        }
        var windowsVal: AnyObject?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &windowsVal) == .success,
              let windows = windowsVal as? [AXUIElement] else { return nil }
        for window in windows {
            for container in children(window) {
                let items = children(container)
                // Scan from the end: the player bar is the last group of controls
                for i in stride(from: items.count - 1, to: 0, by: -1) where desc(items[i]) == "Back" {
                    guard let label = desc(items[i - 1]), let comma = label.firstIndex(of: ",") else { continue }
                    let title = label[..<comma].trimmingCharacters(in: .whitespaces)
                    let artist = label[label.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty { return (title, artist.isEmpty ? "AuMusic" : artist) }
                }
            }
        }
        return nil
    }
    
    public func readAuMusicTrackMeta() -> (title: String, artist: String)? {
        // Priority 1: Inspect AuMusic window UI via Accessibility (live track title + artist)
        if let app = auMusicApplication() {
            if let fast = readAuMusicTrackFromPlayerBar(app) { return fast }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsVal: AnyObject?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsVal) == .success,
               let windows = windowsVal as? [AXUIElement] {
                var trackCandidate: String?
                for w in windows {
                    func scan(_ el: AXUIElement, _ depth: Int = 0) {
                        if trackCandidate != nil || depth > 12 { return }
                        var descVal: AnyObject?
                        AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descVal)
                        if let desc = descVal as? String, !desc.isEmpty {
                            if desc.contains(",") && !desc.contains("Screen") && !desc.contains("Window") && !desc.contains("Update") && !desc.contains("Gear") && !desc.contains("Volume") {
                                let parts = desc.components(separatedBy: ",")
                                if parts.count >= 2 {
                                    let second = parts[1].trimmingCharacters(in: .whitespaces)
                                    if Int(second) == nil {
                                        trackCandidate = desc
                                        return
                                    }
                                }
                            }
                        }
                        var childrenVal: AnyObject?
                        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenVal) == .success,
                           let children = childrenVal as? [AXUIElement] {
                            for c in children { scan(c, depth + 1) }
                        }
                    }
                    scan(w)
                    if let cand = trackCandidate {
                        let parts = cand.components(separatedBy: ",")
                        let title = parts[0].trimmingCharacters(in: .whitespaces)
                        let artist = parts.dropFirst().joined(separator: ",").trimmingCharacters(in: .whitespaces)
                        if !title.isEmpty {
                            return (title, artist.isEmpty ? "AuMusic" : artist)
                        }
                    }
                }
            }
        }
        
        // Priority 2: Fallback to preferences plist
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plistURL = home.appendingPathComponent("Library/Containers/devplaceholder.D6YLB7PC.AuMusic/Data/Library/Preferences/devplaceholder.D6YLB7PC.AuMusic.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] else { return nil }
        
        let possibleTitleKeys = ["currentTrackTitle", "trackTitle", "title", "currentTitle", "playingTrackTitle", "track", "lastPlayedTitle", "songName"]
        let possibleArtistKeys = ["currentArtist", "artist", "trackArtist", "currentArtistName", "artistName", "lastPlayedArtist"]
        
        var foundTitle: String? = nil
        var foundArtist: String? = nil
        
        for k in possibleTitleKeys {
            if let val = dict[k] as? String, !val.isEmpty {
                foundTitle = val
                break
            }
        }
        for k in possibleArtistKeys {
            if let val = dict[k] as? String, !val.isEmpty {
                foundArtist = val
                break
            }
        }
        
        if let t = foundTitle {
            return (t, foundArtist ?? "AuMusic")
        }
        return nil
    }
    
    public func findAuMusicCover() -> NSImage? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let container = home.appendingPathComponent("Library/Containers/devplaceholder.D6YLB7PC.AuMusic/Data")
        
        let subpaths = [
            container.appendingPathComponent("Library/Caches"),
            container.appendingPathComponent("Documents"),
            container.appendingPathComponent("tmp")
        ]
        
        var candidateFiles: [(url: URL, date: Date)] = []
        let fm = FileManager.default
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp"]
        
        for base in subpaths {
            guard let enumerator = fm.enumerator(
                at: base,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            
            while let fileURL = enumerator.nextObject() as? URL {
                if imageExts.contains(fileURL.pathExtension.lowercased()) {
                    if let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                       attrs.isRegularFile == true,
                       let modDate = attrs.contentModificationDate {
                        candidateFiles.append((fileURL, modDate))
                    }
                }
            }
        }
        
        candidateFiles.sort { $0.date > $1.date }
        
        for candidate in candidateFiles.prefix(5) {
            if let img = NSImage(contentsOf: candidate.url), img.size.width >= 30, img.size.height >= 30 {
                return img
            }
        }
        
        return nil
    }
    
    // MARK: - Artwork Fetching & Caching
    
    public func fetchArtwork(for info: DetectedMediaInfo, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = cacheKeyForMedia(info)
        
        // 1. Check RAM Cache
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            DispatchQueue.main.async { completion(cached) }
            return
        }
        
        // 2. Check Disk Cache
        let diskFile = diskCacheURL.appendingPathComponent("\(cacheKey).jpg")
        if FileManager.default.fileExists(atPath: diskFile.path),
           let img = NSImage(contentsOfFile: diskFile.path) {
            memoryCache.setObject(img, forKey: cacheKey as NSString)
            DispatchQueue.main.async { completion(img) }
            return
        }
        
        // 3. Deduplicate Network Requests
        requestLock.lock()
        if var list = activeRequests[cacheKey] {
            list.append(completion)
            activeRequests[cacheKey] = list
            requestLock.unlock()
            return
        } else {
            activeRequests[cacheKey] = [completion]
            requestLock.unlock()
        }
        
        let notifyAll: (NSImage?) -> Void = { [weak self] downloadedImage in
            guard let self = self else { return }
            
            if let img = downloadedImage {
                self.memoryCache.setObject(img, forKey: cacheKey as NSString)
                if let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                    try? jpeg.write(to: diskFile)
                }
            }
            
            self.requestLock.lock()
            let callbacks = self.activeRequests.removeValue(forKey: cacheKey) ?? []
            self.requestLock.unlock()
            
            DispatchQueue.main.async {
                for cb in callbacks {
                    cb(downloadedImage)
                }
            }
        }
        
        switch info.source {
        case .youtube:
            fetchYouTubeThumbnail(info: info, completion: notifyAll)
        case .genericAudio(let app) where app.contains("AuMusic"):
            // 1. Check local container for cached/downloaded album cover
            if let localCover = findAuMusicCover() {
                notifyAll(localCover)
            } else if info.title != "AuMusic" && !info.title.isEmpty {
                // 2. Query iTunes API
                fetchMusicArtwork(query: "\(info.artist) \(info.title)", completion: notifyAll)
            } else {
                notifyAll(nil)
            }
        case .appleMusic, .spotify:
            fetchMusicArtwork(query: "\(info.artist) \(info.title)", completion: notifyAll)
        default:
            if !info.title.isEmpty && info.title != "QuickTime Player" && info.title != "Видео / Аудио" {
                fetchMusicArtwork(query: "\(info.artist) \(info.title)", completion: notifyAll)
            } else {
                notifyAll(nil)
            }
        }
    }
    
    // MARK: - YouTube Thumbnail Engine
    
    private func fetchYouTubeThumbnail(info: DetectedMediaInfo, completion: @escaping (NSImage?) -> Void) {
        // Step 1: If videoId is known, download directly
        if let vid = info.videoId, !vid.isEmpty {
            downloadThumbnail(videoId: vid, completion: completion)
            return
        }
        
        // Step 2: Query YouTube Search HTML to extract videoId
        let query = info.rawQuery.isEmpty ? "\(info.artist) \(info.title)" : info.rawQuery
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://www.youtube.com/results?search_query=\(encoded)") else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: searchURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        // Google consent cookie bypasses consent interstitial
        request.setValue("SOCS=CAESEwgDEgk0ODE3Nzk3MjQaAmVuIAEaBgiA_LyaBg", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 4.0
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, let html = String(data: data, encoding: .utf8) else {
                // If YouTube search fails, fallback to iTunes song search
                self?.fetchMusicArtwork(query: query, completion: completion)
                return
            }
            
            // Look for "videoId":"[11-char]" in HTML
            var extractedVideoId: String? = nil
            if let match = html.range(of: #""videoId":"([a-zA-Z0-9_-]{11})""#, options: .regularExpression) {
                let sub = String(html[match])
                let parts = sub.components(separatedBy: "\"")
                if parts.count >= 4 {
                    extractedVideoId = parts[3]
                }
            }
            if extractedVideoId == nil, let match = html.range(of: #"watch\?v=([a-zA-Z0-9_-]{11})"#, options: .regularExpression) {
                let sub = String(html[match])
                if let range = sub.range(of: #"v=([a-zA-Z0-9_-]{11})"#, options: .regularExpression) {
                    let vPart = String(sub[range])
                    extractedVideoId = String(vPart.dropFirst(2))
                }
            }
            if extractedVideoId == nil, let match = html.range(of: #"\/vi\/([a-zA-Z0-9_-]{11})\/"#, options: .regularExpression) {
                let sub = String(html[match])
                let parts = sub.split(separator: "/")
                if parts.count >= 2 {
                    extractedVideoId = String(parts[1])
                }
            }
            
            if let vid = extractedVideoId {
                self.downloadThumbnail(videoId: vid, completion: completion)
            } else {
                // Fallback to iTunes song cover
                self.fetchMusicArtwork(query: query, completion: completion)
            }
        }
        task.resume()
    }
    
    private func downloadThumbnail(videoId: String, completion: @escaping (NSImage?) -> Void) {
        let urls = [
            URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"),
            URL(string: "https://img.youtube.com/vi/\(videoId)/hqdefault.jpg"),
            URL(string: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg"),
            URL(string: "https://img.youtube.com/vi/\(videoId)/mqdefault.jpg")
        ].compactMap { $0 }
        
        func tryDownload(index: Int) {
            guard index < urls.count else {
                completion(nil)
                return
            }
            var request = URLRequest(url: urls[index])
            request.timeoutInterval = 3.5
            URLSession.shared.dataTask(with: request) { data, _, _ in
                if let d = data, let img = NSImage(data: d), img.size.width > 120 {
                    completion(img)
                } else {
                    tryDownload(index: index + 1)
                }
            }.resume()
        }
        
        tryDownload(index: 0)
    }
    
    // MARK: - iTunes Search API for High-Res Album Artwork
    
    public func fetchMusicArtwork(query: String, completion: @escaping (NSImage?) -> Void) {
        let cleanQuery = query.replacingOccurrences(of: #"\s*\(.*?\)"#, with: "", options: .regularExpression)
                              .replacingOccurrences(of: #"\s*\[.*?\]"#, with: "", options: .regularExpression)
                              .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let encoded = cleanQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=song&limit=1") else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.5
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let artworkUrlString = first["artworkUrl100"] as? String else {
                completion(nil)
                return
            }
            
            // Replace 100x100 with 600x600 for crisp Retina quality
            let hiResString = artworkUrlString.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let artURL = URL(string: hiResString) else {
                completion(nil)
                return
            }
            
            URLSession.shared.dataTask(with: artURL) { imgData, _, _ in
                if let idata = imgData, let img = NSImage(data: idata) {
                    completion(img)
                } else {
                    completion(nil)
                }
            }.resume()
        }.resume()
    }
    
    // MARK: - Stylish Placeholders (Zero Generic Browser Icons)
    
    public func placeholderArtwork(for source: MediaSourceType) -> NSImage {
        switch source {
        case .youtube:
            return youtubeBadgeImage()
        case .quickTime:
            return quickTimeBadgeImage()
        default:
            return musicBadgeImage()
        }
    }
    
    public func youtubeBadgeImage() -> NSImage {
        let size = NSSize(width: 48, height: 48)
        let img = NSImage(size: size)
        img.lockFocus()
        
        // YouTube Reddish / Dark Slate background
        let bg = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 10, yRadius: 10)
        let gradient = NSGradient(starting: NSColor(red: 0.90, green: 0.12, blue: 0.15, alpha: 1.0),
                                  ending: NSColor(red: 0.60, green: 0.05, blue: 0.08, alpha: 1.0))
        gradient?.draw(in: bg, angle: -45)
        
        // Centered white play triangle
        let play = NSBezierPath()
        play.move(to: NSPoint(x: 18, y: 15))
        play.line(to: NSPoint(x: 18, y: 33))
        play.line(to: NSPoint(x: 34, y: 24))
        play.close()
        NSColor.white.setFill()
        play.fill()
        
        img.unlockFocus()
        return img
    }
    
    public func musicBadgeImage() -> NSImage {
        let size = NSSize(width: 48, height: 48)
        let img = NSImage(size: size)
        img.lockFocus()
        
        let bg = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 10, yRadius: 10)
        let gradient = NSGradient(starting: NSColor(red: 0.25, green: 0.28, blue: 0.40, alpha: 1.0),
                                  ending: NSColor(red: 0.12, green: 0.14, blue: 0.22, alpha: 1.0))
        gradient?.draw(in: bg, angle: -45)
        
        if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .bold)
            let configured = note.withSymbolConfiguration(config)
            NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1.0).set()
            configured?.draw(in: NSRect(x: 13, y: 13, width: 22, height: 22))
        }
        
        img.unlockFocus()
        return img
    }
    
    public func quickTimeBadgeImage() -> NSImage {
        let size = NSSize(width: 48, height: 48)
        let img = NSImage(size: size)
        img.lockFocus()
        
        let bg = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 10, yRadius: 10)
        let gradient = NSGradient(starting: NSColor(red: 0.18, green: 0.55, blue: 0.90, alpha: 1.0),
                                  ending: NSColor(red: 0.08, green: 0.25, blue: 0.55, alpha: 1.0))
        gradient?.draw(in: bg, angle: -45)
        
        if let play = NSImage(systemSymbolName: "film.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .bold)
            let configured = play.withSymbolConfiguration(config)
            NSColor.white.set()
            configured?.draw(in: NSRect(x: 14, y: 14, width: 20, height: 20))
        }
        
        img.unlockFocus()
        return img
    }
    
    // MARK: - Cache Key Helper
    
    private func cacheKeyForMedia(_ info: DetectedMediaInfo) -> String {
        if let vid = info.videoId, !vid.isEmpty {
            return "yt_\(vid)"
        }
        let raw = "\(info.source)_\(info.artist)_\(info.title)"
        let safe = raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let str = String(safe)
        return str.isEmpty ? "media_unknown" : String(str.prefix(50))
    }
}

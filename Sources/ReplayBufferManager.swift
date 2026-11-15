import Foundation
import AVFoundation
import CoreMedia

public struct BufferChunk {
    public let url: URL
    public let startTime: Date
    public let duration: TimeInterval
}

public final class ReplayBufferManager {
    public static let shared = ReplayBufferManager()
    
    private let queue = DispatchQueue(label: "com.local.notchy.replaybuffer", qos: .utility)
    private var activeChunks: [BufferChunk] = []
    
    public var bufferDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("Notchy").appendingPathComponent("ReplayBuffer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private init() {
        clearBuffer()
    }
    
    public func clearBuffer() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.activeChunks.removeAll()
            let dir = self.bufferDirectory
            if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for item in items where item.pathExtension == "mp4" {
                    try? FileManager.default.removeItem(at: item)
                }
            }
        }
    }
    
    public func createNewChunkURL() -> URL {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        return bufferDirectory.appendingPathComponent("chunk_\(ts).mp4")
    }
    
    public func registerCompletedChunk(url: URL, startTime: Date, duration: TimeInterval, maxRetentionSeconds: TimeInterval) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            
            let chunk = BufferChunk(url: url, startTime: startTime, duration: duration)
            self.activeChunks.append(chunk)
            
            // Prune chunks that fall completely outside the retention window
            let cutoff = Date().addingTimeInterval(-maxRetentionSeconds - 30.0) // 30s grace margin
            var kept: [BufferChunk] = []
            for item in self.activeChunks {
                let itemEnd = item.startTime.addingTimeInterval(item.duration)
                if itemEnd < cutoff {
                    try? FileManager.default.removeItem(at: item.url)
                } else {
                    kept.append(item)
                }
            }
            self.activeChunks = kept
        }
    }
    
    /// Stitches the last `durationSeconds` of buffered video into a single output MP4 without re-encoding
    public func exportReplay(
        durationSeconds: TimeInterval,
        outputFolder: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(.failure(NSError(domain: "ReplayBuffer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service unavailable"])))
                return
            }
            
            let validChunks = self.activeChunks.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            guard !validChunks.isEmpty else {
                completion(.failure(NSError(domain: "ReplayBuffer", code: -2, userInfo: [NSLocalizedDescriptionKey: tr("Нет записанных фрагментов в буфере", "No recorded fragments in the buffer")])))
                return
            }
            
            // Calculate total available duration
            let totalDuration = validChunks.reduce(0.0) { $0 + $1.duration }
            let requestedDuration = min(durationSeconds, totalDuration)
            
            // Select chunks from the end that cover the requested duration
            var selectedChunks: [BufferChunk] = []
            var accumulated: TimeInterval = 0.0
            for chunk in validChunks.reversed() {
                selectedChunks.insert(chunk, at: 0)
                accumulated += chunk.duration
                if accumulated >= requestedDuration {
                    break
                }
            }
            
            let composition = AVMutableComposition()
            guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                completion(.failure(NSError(domain: "ReplayBuffer", code: -3, userInfo: [NSLocalizedDescriptionKey: tr("Не удалось создать видеодорожку", "Could not create the video track")])))
                return
            }
            
            // Support all audio tracks in chunks (e.g. track 0 = system audio, track 1 = microphone)
            var maxAudioTracks = 0
            for chunk in selectedChunks {
                let asset = AVURLAsset(url: chunk.url)
                let count = asset.tracks(withMediaType: .audio).count
                if count > maxAudioTracks {
                    maxAudioTracks = count
                }
            }
            
            var compAudioTracks: [AVMutableCompositionTrack] = []
            for _ in 0..<maxAudioTracks {
                if let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    compAudioTracks.append(track)
                }
            }
            
            var insertCursor = CMTime.zero
            
            for chunk in selectedChunks {
                let asset = AVURLAsset(url: chunk.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                let duration = asset.duration
                
                if let videoTrack = asset.tracks(withMediaType: .video).first {
                    let vRange = videoTrack.timeRange.duration > .zero ? videoTrack.timeRange : CMTimeRange(start: .zero, duration: duration)
                    try? compVideoTrack.insertTimeRange(vRange, of: videoTrack, at: insertCursor)
                }
                
                let chunkAudioTracks = asset.tracks(withMediaType: .audio)
                for (idx, audioTrack) in chunkAudioTracks.enumerated() {
                    guard idx < compAudioTracks.count else { break }
                    let compAudio = compAudioTracks[idx]
                    let aRange = audioTrack.timeRange.duration > .zero ? audioTrack.timeRange : CMTimeRange(start: .zero, duration: duration)
                    try? compAudio.insertTimeRange(aRange, of: audioTrack, at: insertCursor)
                }
                
                insertCursor = CMTimeAdd(insertCursor, duration)
            }
            
            // Format output filename: Replay_2026-10-25_21-00-15.mp4
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let dateStr = formatter.string(from: Date())
            try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            let outputURL = outputFolder.appendingPathComponent("Replay_\(dateStr).mp4")
            
            try? FileManager.default.removeItem(at: outputURL)
            
            // Fast passthrough export (stream-copy, zero CPU re-encoding!)
            guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                completion(.failure(NSError(domain: "ReplayBuffer", code: -4, userInfo: [NSLocalizedDescriptionKey: tr("Ошибка создания сессии экспорта", "Could not create the export session")])))
                return
            }
            
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
            exportSession.shouldOptimizeForNetworkUse = false
            
            exportSession.exportAsynchronously {
                DispatchQueue.main.async {
                    switch exportSession.status {
                    case .completed:
                        completion(.success(outputURL))
                    case .failed:
                        let err = exportSession.error ?? NSError(domain: "ReplayBuffer", code: -5, userInfo: [NSLocalizedDescriptionKey: tr("Экспорт не удался", "Export failed")])
                        completion(.failure(err))
                    case .cancelled:
                        completion(.failure(NSError(domain: "ReplayBuffer", code: -6, userInfo: [NSLocalizedDescriptionKey: tr("Экспорт отменен", "Export cancelled")])))
                    default:
                        completion(.failure(NSError(domain: "ReplayBuffer", code: -7, userInfo: [NSLocalizedDescriptionKey: tr("Неизвестная ошибка экспорта", "Unknown export error")])))
                    }
                }
            }
        }
    }
}

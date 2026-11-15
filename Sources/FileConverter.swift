import Foundation
import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// MARK: - Targets

public enum FileCategory {
    case image, video, audio, document, pdf, other

    var tint: NSColor {
        switch self {
        case .image: return .systemOrange
        case .video: return .systemPurple
        case .audio: return .systemGreen
        case .document: return .systemBlue
        case .pdf: return .systemRed
        case .other: return .systemGray
        }
    }
}

public struct ConversionTarget: Identifiable, Hashable {
    public let ext: String
    public let title: String
    /// Needs the ffmpeg command line tool (offered only when it is installed)
    public let needsFFmpeg: Bool
    public var id: String { ext + (needsFFmpeg ? "-ff" : "") }

    init(_ ext: String, _ title: String, ffmpeg: Bool = false) {
        self.ext = ext
        self.title = title
        self.needsFFmpeg = ffmpeg
    }
}

// MARK: - Converter

/// Converts dropped files into other formats and writes the copy to Downloads. Everything the system can do natively
/// (ImageIO, AVFoundation, AppKit documents, PDFKit, ditto) is built in; ffmpeg, if installed, adds the rest.
public enum FileConverter {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "flac", "ogg", "oga", "opus", "aiff", "aif", "caf", "wma", "amr", "alac"]
    static let documentExtensions: Set<String> = ["txt", "rtf", "rtfd", "html", "htm", "md", "markdown", "docx", "doc", "odt", "csv", "json", "xml", "log"]

    static let cwebpPath: String? = {
        ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }()
    
    static let ffmpegPath: String? = {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    // MARK: Which blocks to offer

    public static func category(of url: URL) -> FileCategory {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return .other }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if documentExtensions.contains(ext) { return .document }
        // Audio first: M4A and friends also conform to the movie type (MPEG-4 container), which made audio look like video
        if audioExtensions.contains(ext) { return .audio }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            // A video container without a picture track (voice messages, audio saved as .mp4) is audio
            let asset = AVURLAsset(url: url)
            if asset.tracks(withMediaType: .video).isEmpty && !asset.tracks(withMediaType: .audio).isEmpty { return .audio }
            return .video
        }
        if type.conforms(to: .audio) { return .audio }
        return .other
    }

    /// One category for the whole drop; mixed drops get only the archive.
    public static func category(of urls: [URL]) -> FileCategory {
        let cats = Set(urls.map { category(of: $0) })
        return cats.count == 1 ? cats.first! : .other
    }

    public static func targets(for urls: [URL]) -> [ConversionTarget] {
        let category = category(of: urls)
        // Order: what people reach for most comes first (the left column is filled first), rarer and
        // lossless/archive formats follow, "extract audio" sits after the video formats, ZIP is always last.
        var list: [ConversionTarget]
        switch category {
        case .image:
            list = [.init("png", "PNG"), .init("jpg", "JPEG"), .init("heic", "HEIC"), .init("webp", "WebP"), .init("gif", "GIF"),
                    .init("pdf", "PDF"), .init("tiff", "TIFF"), .init("bmp", "BMP"), .init("jp2", "JPEG 2000")]
        case .video:
            list = [.init("mp4", "MP4"), .init("mov", "MOV"), .init("hevc.mp4", "HEVC"), .init("m4v", "M4V"), .init("webm", "WebM", ffmpeg: true),
                    .init("mkv", "MKV", ffmpeg: true), .init("avi", "AVI", ffmpeg: true), .init("gif", "GIF", ffmpeg: true),
                    .init("mp3", "MP3", ffmpeg: true), .init("m4a", "M4A")]
        case .audio:
            list = [.init("mp3", "MP3", ffmpeg: true), .init("m4a", "AAC"), .init("wav", "WAV"), .init("flac", "FLAC"), .init("alac.m4a", "ALAC"),
                    .init("ogg", "OGG", ffmpeg: true), .init("opus", "Opus", ffmpeg: true), .init("aiff", "AIFF"), .init("caf", "CAF")]
        case .document:
            list = [.init("pdf", "PDF"), .init("docx", "DOCX"), .init("txt", "TXT"), .init("rtf", "RTF"), .init("html", "HTML"), .init("odt", "ODT")]
        case .pdf:
            list = [.init("png", "PNG"), .init("jpg", "JPEG"), .init("txt", "TXT")]
        case .other:
            list = []
        }
        list = list.filter { !$0.needsFFmpeg || ffmpegPath != nil }
        list = list.filter { $0.ext != "webp" || cwebpPath != nil }
        list.append(.init("zip", "ZIP"))
        return list
    }

    private static func normalized(_ ext: String) -> String {
        let e = ext.lowercased()
        return e == "jpeg" ? "jpg" : (e == "tif" ? "tiff" : (e == "htm" ? "html" : e))
    }

    // MARK: Convert

    struct ConversionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Converts each file (or archives them all for ZIP) into Downloads and returns the created files.
    public static func convert(_ urls: [URL], to target: ConversionTarget) async throws -> [URL] {
        if target.ext == "zip" { return [try zip(urls)] }
        var results: [URL] = []
        for src in urls {
            let out = uniqueOutputURL(for: src, ext: target.ext.replacingOccurrences(of: "hevc.", with: "").replacingOccurrences(of: "alac.", with: ""))
            if normalized(src.pathExtension) == normalized(target.ext) {
                // Already in this format: a lossless copy to Downloads instead of re-encoding
                try FileManager.default.copyItem(at: src, to: out)
            } else if target.needsFFmpeg {
                try await runFFmpeg(src, out, ext: target.ext)
            } else if target.ext == "webp" {
                try await convertToWebP(src, out)
            } else {
                switch category(of: src) {
                case .image: try convertImage(src, to: target.ext, out: out)
                case .video: try await convertVideo(src, to: target.ext, out: out)
                case .audio: try convertAudio(src, to: target.ext, out: out)
                case .document: try await convertDocument(src, to: target.ext, out: out)
                case .pdf: try convertPDF(src, to: target.ext, out: out)
                case .other: throw ConversionError(message: tr("Формат не поддерживается", "Format not supported"))
                }
            }
            results.append(out)
        }
        return results
    }

    static func uniqueOutputURL(for src: URL, ext: String) -> URL {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        let base = src.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: ZIP (any file or folder)

    private static func zip(_ urls: [URL]) throws -> URL {
        let name = urls.count == 1 ? urls[0] : URL(fileURLWithPath: tr("Архив", "Archive"))
        let out = uniqueOutputURL(for: name, ext: "zip")
        var source = urls[0]
        var temp: URL?
        if urls.count > 1 {
            // Several items: gather them in one folder so the archive has a single root
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Notchy-\(UUID().uuidString)/Архив", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for url in urls { try? FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(url.lastPathComponent)) }
            source = dir
            temp = dir.deletingLastPathComponent()
        }
        defer { if let temp = temp { try? FileManager.default.removeItem(at: temp) } }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, out.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw ConversionError(message: tr("Не удалось создать архив", "Could not create the archive")) }
        return out
    }

    // MARK: Images

    private static func convertImage(_ src: URL, to ext: String, out: URL) throws {
        guard let image = loadImage(src) else { throw ConversionError(message: tr("Не удалось открыть изображение", "Could not open the image")) }
        try writeImage(image, to: out, ext: ext)
    }

    /// Decodes with the EXIF orientation applied (a plain decode would write phone photos rotated).
    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func writeImage(_ image: CGImage, to out: URL, ext: String) throws {
        if ext == "pdf" {
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw ConversionError(message: tr("Не удалось создать PDF", "Could not create the PDF")) }
            ctx.beginPDFPage(nil)
            ctx.draw(image, in: box)
            ctx.endPDFPage()
            ctx.closePDF()
            return
        }
        let types: [String: String] = ["jpg": "public.jpeg", "png": "public.png", "heic": "public.heic", "tiff": "public.tiff",
                                       "gif": "com.compuserve.gif", "bmp": "com.microsoft.bmp", "jp2": "public.jpeg-2000"]
        guard let type = types[ext] else { throw ConversionError(message: tr("Формат {0} не поддерживается", "Format {0} is not supported", ext)) }
        // JPEG and BMP have no transparency: flatten onto white instead of getting a black background
        let source = (ext == "jpg" || ext == "bmp") ? (flattened(image) ?? image) : image
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) else {
            throw ConversionError(message: tr("Формат {0} недоступен на этом Mac", "Format {0} is not available on this Mac", ext.uppercased()))
        }
        let props: [CFString: Any] = (ext == "jpg" || ext == "heic") ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(dest, source, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError(message: tr("Не удалось сохранить изображение", "Could not save the image")) }
    }

    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    // MARK: Video

    private static func convertVideo(_ src: URL, to ext: String, out: URL) async throws {
        let asset = AVURLAsset(url: src)
        let (preset, type): (String, AVFileType)
        switch ext {
        case "mp4": (preset, type) = (AVAssetExportPresetHighestQuality, .mp4)
        case "hevc.mp4": (preset, type) = (AVAssetExportPresetHEVCHighestQuality, .mp4)
        case "mov": (preset, type) = (AVAssetExportPresetHighestQuality, .mov)
        case "m4v": (preset, type) = (AVAssetExportPresetHighestQuality, .m4v)
        case "m4a": (preset, type) = (AVAssetExportPresetAppleM4A, .m4a)
        default: throw ConversionError(message: tr("Формат {0} не поддерживается", "Format {0} is not supported", ext))
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError(message: tr("Этот формат нельзя получить из исходного видео", "This format can't be made from the source video"))
        }
        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = ext == "mp4"
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed else {
            throw ConversionError(message: session.error?.localizedDescription ?? tr("Не удалось конвертировать видео", "Could not convert the video"))
        }
    }

    // MARK: Audio

    private static func convertAudio(_ src: URL, to ext: String, out: URL) throws {
        let input = try AVAudioFile(forReading: src)
        let format = input.processingFormat
        var settings: [String: Any]
        switch ext {
        case "m4a":
            // Re-encode as AAC; rates above 48 kHz gain nothing at this bitrate
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: min(format.sampleRate, 48000),
                        AVNumberOfChannelsKey: min(format.channelCount, 2), AVEncoderBitRateKey: 256_000]
        case "alac.m4a":
            settings = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount]
        case "flac":
            settings = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount]
        case "wav", "aiff", "caf":
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: ext == "aiff"]
        default:
            throw ConversionError(message: tr("Формат {0} не поддерживается", "Format {0} is not supported", ext))
        }
        let output = try AVAudioFile(forWriting: out, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else { throw ConversionError(message: tr("Нет памяти для буфера", "Out of memory for the buffer")) }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }

    // MARK: Documents

    @MainActor
    private static func convertDocument(_ src: URL, to ext: String, out: URL) async throws {
        let isPlain = ["txt", "md", "markdown", "csv", "json", "xml", "log"].contains(src.pathExtension.lowercased())
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = isPlain ? [.documentType: NSAttributedString.DocumentType.plain] : [:]
        guard let text = try? NSAttributedString(url: src, options: options, documentAttributes: nil) else {
            throw ConversionError(message: tr("Не удалось прочитать документ", "Could not read the document"))
        }
        let range = NSRange(location: 0, length: text.length)
        func write(_ type: NSAttributedString.DocumentType) throws {
            let data = try text.data(from: range, documentAttributes: [.documentType: type])
            try data.write(to: out, options: .atomic)
        }
        switch ext {
        case "txt": try text.string.write(to: out, atomically: true, encoding: .utf8)
        case "rtf": try write(.rtf)
        case "html": try write(.html)
        case "docx": try write(.officeOpenXML)
        case "odt": try write(.openDocument)
        case "pdf":
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 595, height: 842))
            view.textStorage?.setAttributedString(text)
            view.textContainerInset = NSSize(width: 36, height: 36)
            let info = NSPrintInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
            let op = NSPrintOperation(view: view, printInfo: info)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            guard op.run() else { throw ConversionError(message: tr("Не удалось создать PDF", "Could not create the PDF")) }
        default: throw ConversionError(message: tr("Формат {0} не поддерживается", "Format {0} is not supported", ext))
        }
    }

    // MARK: PDF

    private static func convertPDF(_ src: URL, to ext: String, out: URL) throws {
        guard let doc = PDFDocument(url: src) else { throw ConversionError(message: tr("Не удалось открыть PDF", "Could not open the PDF")) }
        if ext == "txt" {
            try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)
            return
        }
        // First page at 2x
        guard let page = doc.page(at: 0) else { throw ConversionError(message: tr("В PDF нет страниц", "The PDF has no pages")) }
        let box = page.bounds(for: .mediaBox)
        let image = page.thumbnail(of: NSSize(width: box.width * 2, height: box.height * 2), for: .mediaBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ConversionError(message: tr("Не удалось отрисовать страницу", "Could not render the page")) }
        try writeImage(cg, to: out, ext: ext)
    }

    // MARK: ffmpeg

    private static func runFFmpeg(_ src: URL, _ out: URL, ext: String) async throws {
        guard let ffmpeg = ffmpegPath else { throw ConversionError(message: tr("ffmpeg не найден", "ffmpeg not found")) }
        let args: [String]
        switch ext {
        case "mp3": args = ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "ogg": args = ["-vn", "-c:a", "libopus", "-b:a", "160k"] // this ffmpeg build has no Vorbis encoder; Ogg + Opus plays everywhere
        case "opus": args = ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case "webm": args = ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]
        case "mkv": args = ["-c", "copy"]
        case "avi": args = ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame"]
        case "gif": args = ["-vf", "fps=12,scale=480:-1:flags=lanczos", "-loop", "0", "-an"]
        default: args = []
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ffmpeg)
            task.arguments = ["-y", "-i", src.path] + args + [out.path]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { p in
                if p.terminationStatus == 0 { cont.resume() }
                else { cont.resume(throwing: ConversionError(message: tr("ffmpeg не смог конвертировать файл", "ffmpeg could not convert the file"))) }
            }
            do { try task.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// WebP: ImageIO cannot write it, so decode with ImageIO (keeps EXIF rotation, reads HEIC etc.) and encode with cwebp.
    private static func convertToWebP(_ src: URL, _ out: URL) async throws {
        guard let cwebp = cwebpPath else { throw ConversionError(message: tr("cwebp не найден", "cwebp not found")) }
        guard let image = loadImage(src) else { throw ConversionError(message: tr("Не удалось открыть изображение", "Could not open the image")) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try writeImage(image, to: temp, ext: "png")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: cwebp)
            task.arguments = ["-q", "90", temp.path, "-o", out.path]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { p in
                if p.terminationStatus == 0 { cont.resume() }
                else { cont.resume(throwing: ConversionError(message: tr("cwebp не смог конвертировать файл", "cwebp could not convert the file"))) }
            }
            do { try task.run() } catch { cont.resume(throwing: error) }
        }
    }
    
    // MARK: Drag helpers

    /// File URLs of the drag currently in progress (readable from the drag pasteboard before the drop).
    public static func urlsBeingDragged() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }
}

// MARK: - Job status for the UI

public final class ConversionCenter: ObservableObject {
    public static let shared = ConversionCenter()

    public enum Status: Equatable {
        case running(String)
        case done(name: String, url: URL)
        case failed(String)
    }

    @Published public private(set) var status: Status?
    private var clearWork: DispatchWorkItem?

    public func start(_ urls: [URL], target: ConversionTarget) {
        guard !urls.isEmpty else { return }
        set(.running("\(target.title)…"))
        Task { [weak self] in
            do {
                let results = try await FileConverter.convert(urls, to: target)
                let first = results[0]
                let name = results.count > 1 ? tr("{0} файла", "{0} files", results.count) : first.lastPathComponent
                await MainActor.run {
                    self?.set(.done(name: name, url: first), clearAfter: 6)
                    NotificationService.shared.sendRecordingNotification(title: tr("Готово: {0}", "Done: {0}", target.title), body: tr("{0} — в Загрузках", "{0} — in Downloads", name))
                }
            } catch {
                await MainActor.run { self?.set(.failed(error.localizedDescription), clearAfter: 6) }
            }
        }
    }

    private func set(_ new: Status, clearAfter seconds: Double? = nil) {
        clearWork?.cancel()
        DispatchQueue.main.async {
            self.status = new
        }
        if let seconds = seconds {
            let work = DispatchWorkItem { [weak self] in self?.status = nil }
            clearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }
}

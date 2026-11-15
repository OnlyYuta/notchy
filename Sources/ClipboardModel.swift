import Foundation

public struct ClipboardItem: Identifiable, Codable, Equatable {
    public enum Kind: String, Codable {
        case text    // copied or dropped text
        case file    // files and folders dropped on the notch (stored by reference)
        case image   // image dropped without a file (e.g. from a browser); saved as a PNG in the app's folder
    }
    
    public let id: UUID
    /// Text for `.text`; display names for files/images (used for preview and search).
    public let text: String
    public let timestamp: Date
    public let kind: Kind
    /// File/folder/image paths for non-text items.
    public let paths: [String]
    
    public init(id: UUID = UUID(), text: String, timestamp: Date = Date(), kind: Kind = .text, paths: [String] = []) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.kind = kind
        self.paths = paths
    }
    
    // History saved by earlier versions has no kind/paths
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
    }
    
    public var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }
    
    public var characterCount: Int {
        text.count
    }
    
    public var characterCountString: String {
        if kind != .text { return objectSummary }
        let unit = LocalizationService.shared.t(.clipboardChars)
        return "\(characterCount) \(unit)"
    }
    
    /// "Папка", "Файл · 2,3 МБ", "3 объекта", "Изображение"
    public var objectSummary: String {
        let ru = LocalizationService.shared.currentLanguage == .ru
        if kind == .image { return tr("Изображение", "Image") }
        if paths.count > 1 { return tr("{0} объектов", "{0} items", paths.count) }
        guard let path = paths.first else { return "" }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return tr("Файл недоступен", "File unavailable") }
        if isDir.boolValue { return tr("Папка", "Folder") }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return (tr("Файл · ", "File · ")) + sizeText
    }
    
    public var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: " ⏎ ")
    }
    
    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df
    }()
    
    private static let dateTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "dd.MM HH:mm"
        return df
    }()
    
    public var relativeTimeString: String {
        let elapsed = Date().timeIntervalSince(timestamp)
        if elapsed < 30 {
            return tr("только что", "just now")
        } else if elapsed < 60 {
            return tr("минуту назад", "1m ago")
        } else if elapsed < 3600 {
            let minutes = max(1, Int(elapsed / 60))
            return tr("{0} мин назад", "{0}m ago", minutes)
        } else if elapsed < 86400 {
            return Self.timeFormatter.string(from: timestamp)
        } else {
            return Self.dateTimeFormatter.string(from: timestamp)
        }
    }
}

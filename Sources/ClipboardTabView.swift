import SwiftUI
import AppKit

public struct ClipboardTabView: View {
    @ObservedObject private var clipboardService = ClipboardService.shared
    @ObservedObject private var l10n = LocalizationService.shared
    @State private var hoveredItemId: UUID? = nil
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 6) {
            // Sub-header: Count and Clear Button
            HStack {
                Text(countText)
                    .font(.system(size: 10.0, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                
                Spacer()
                
                if !clipboardService.items.isEmpty {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            clipboardService.clearAll()
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 9.5))
                            Text(l10n.t(.clipboardClear))
                                .font(.system(size: 10.0, weight: .medium, design: .rounded))
                        }
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .help(l10n.t(.clipboardClearHelp))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 3)
            
            // Content List or Empty State
            if clipboardService.items.isEmpty {
                // Icon sits beside the title: stacked it overflowed the 109 pt content area and pushed the whole notch up
                VStack(spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 13.0, weight: .medium))
                            .foregroundColor(.white.opacity(0.35))
                        Text(l10n.t(.clipboardEmpty))
                            .font(.system(size: 12.0, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.75))
                    }
                    
                    Text(l10n.t(.clipboardEmptyHint))
                        .font(.system(size: 10.0, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 12)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 5) {
                        ForEach(clipboardService.items) { item in
                            ClipboardRowView(
                                item: item,
                                isJustPasted: clipboardService.justPastedId == item.id,
                                isHovered: hoveredItemId == item.id,
                                onPaste: {
                                    clipboardService.paste(item: item)
                                },
                                onDelete: {
                                    clipboardService.delete(item: item)
                                }
                            )
                            .onHover { inside in
                                hoveredItemId = inside ? item.id : nil
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var countText: String {
        let count = clipboardService.items.count
        if count == 0 {
            return tr("Нет записей", "No items")
        }
        if l10n.currentLanguage != .ru {
            return count == 1 ? tr("", "{0} item", count) : tr("", "{0} items", count)
        }
        let remainder10 = count % 10
        let remainder100 = count % 100
        let word: String
        if remainder100 >= 11 && remainder100 <= 19 {
            word = "записей"
        } else if remainder10 == 1 {
            word = "запись"
        } else if remainder10 >= 2 && remainder10 <= 4 {
            word = "записи"
        } else {
            word = "записей"
        }
        return "\(count) \(word)"
    }
}

// MARK: - Icon of a dropped file / folder / image

private let clipboardIconCache = NSCache<NSString, NSImage>()

private struct ClipboardObjectIcon: View {
    let item: ClipboardItem
    
    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .scaledToFit()
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(FileManager.default.fileExists(atPath: item.paths.first ?? "") ? 1.0 : 0.35)
    }
    
    /// Image items and image files show a thumbnail, everything else the Finder icon. Cached: rows redraw often.
    private var icon: NSImage {
        let path = item.paths.first ?? ""
        let key = "\(item.id)-\(item.paths.count)" as NSString
        if let cached = clipboardIconCache.object(forKey: key) { return cached }
        let ext = (path as NSString).pathExtension.lowercased()
        let isImage = item.kind == .image || ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp", "bmp"].contains(ext)
        let image: NSImage
        if item.paths.count == 1, isImage, let thumb = NSImage(contentsOfFile: path) {
            image = thumb
        } else if item.paths.count > 1 {
            image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil) ?? NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSWorkspace.shared.icon(forFile: path)
        }
        clipboardIconCache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - Single Item Row View

private struct ClipboardRowView: View {
    let item: ClipboardItem
    let isJustPasted: Bool
    let isHovered: Bool
    let onPaste: () -> Void
    let onDelete: () -> Void
    
    @ObservedObject private var l10n = LocalizationService.shared
    
    var body: some View {
        Button(action: onPaste) {
            HStack(spacing: 9) {
                // Left Icon / Paste Indicator
                ZStack {
                    if isJustPasted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14.0, weight: .semibold))
                            .foregroundColor(.green)
                            .transition(.scale.combined(with: .opacity))
                    } else if item.kind == .text {
                        Image(systemName: "doc.text")
                            .font(.system(size: 12.0, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                    } else {
                        ClipboardObjectIcon(item: item)
                    }
                }
                .frame(width: item.kind == .text ? 16 : 26)
                
                // Middle: Text Snippet & Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.preview)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    HStack(spacing: 5) {
                        Text(item.relativeTimeString)
                            .font(.system(size: 9.5, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                        
                        Text("•")
                            .font(.system(size: 8.0))
                            .foregroundColor(.white.opacity(0.3))
                        
                        Text(item.characterCountString)
                            .font(.system(size: 9.5, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                        
                        Spacer()
                    }
                }
                
                Spacer()
                
                // Right: Action Badge or Delete button
                if isJustPasted {
                    Text(tr("Вставлено", "Pasted"))
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.green.opacity(0.18))
                        )
                } else if isHovered {
                    HStack(spacing: 6) {
                        // Quick hint: Click to paste
                        HStack(spacing: 2.5) {
                            Image(systemName: "cursorarrow.click")
                                .font(.system(size: 9.0, weight: .semibold))
                            Text(tr("Вставить", "Paste"))
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.16))
                        )
                        
                        // Delete Button
                        Button(action: onDelete) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(.white.opacity(0.55))
                                .frame(width: 16, height: 16)
                                .background(
                                    Circle()
                                        .fill(Color.white.opacity(0.1))
                                )
                        }
                        .buttonStyle(.plain)
                        .help(tr("Удалить из истории", "Delete item"))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9.0)
                    .fill(isJustPasted ? Color.green.opacity(0.12) : (isHovered ? Color.white.opacity(0.12) : Color.white.opacity(0.06)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9.0)
                    .stroke(isJustPasted ? Color.green.opacity(0.35) : (isHovered ? Color.white.opacity(0.15) : Color.clear), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

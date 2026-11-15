import SwiftUI
import AppKit

public struct TrackArtworkView: View {
    public var image: NSImage?
    public var size: CGFloat = 15.0
    
    public init(image: NSImage? = nil, size: CGFloat = 15.0) {
        self.image = image
        self.size = size
    }
    
    public var body: some View {
        let radius = size * 0.22
        
        ZStack {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
            } else {
                // Fallback gradient with music note
                RoundedRectangle(cornerRadius: radius)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.22, green: 0.25, blue: 0.35),
                                Color(red: 0.12, green: 0.14, blue: 0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.55, weight: .bold))
                            .foregroundColor(Color(red: 0.25, green: 0.85, blue: 0.55))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: radius)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.4), radius: 2, y: 1)
    }
}

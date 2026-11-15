import SwiftUI

public struct NotchShape: Shape {
    public var bottomRadius: CGFloat
    private let earRadius: CGFloat = 6
    
    public var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }
    
    public init(bottomRadius: CGFloat = 11) {
        self.bottomRadius = bottomRadius
    }
    
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = max(0, min(bottomRadius, min(rect.width / 2, rect.height)))
        
        // Extend top boundary slightly upward (-10 pt) to guarantee zero gap or top antialiasing at the bezel
        let topY = rect.minY - 10.0
        
        // Concave "ears" at the top edge, like the real notch where it meets the menu bar
        let e = min(earRadius, r)
        path.move(to: CGPoint(x: rect.minX - e, y: topY))
        path.addLine(to: CGPoint(x: rect.maxX + e, y: topY))
        path.addLine(to: CGPoint(x: rect.maxX + e, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX + e, y: rect.minY + e), radius: e,
                    startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + e))
        path.addArc(center: CGPoint(x: rect.minX - e, y: rect.minY + e), radius: e,
                    startAngle: .degrees(0), endAngle: .degrees(270), clockwise: true)
        path.closeSubpath()
        return path
    }
}

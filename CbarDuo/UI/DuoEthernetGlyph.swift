import SwiftUI

// Compact Ethernet glyph: short, bold chevrons hugging three tightly packed dots  < ••• >
struct DuoEthernetGlyph: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        let w = size * 1.65
        let h = size * 1.4
        let cx = w / 2
        let cy = h / 2

        ZStack {
            // Left <
            Path { p in
                p.move(to: CGPoint(x: cx - outerX, y: cy - halfH))
                p.addLine(to: CGPoint(x: cx - tipX, y: cy))
                p.addLine(to: CGPoint(x: cx - outerX, y: cy + halfH))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            // Right >
            Path { p in
                p.move(to: CGPoint(x: cx + outerX, y: cy - halfH))
                p.addLine(to: CGPoint(x: cx + tipX, y: cy))
                p.addLine(to: CGPoint(x: cx + outerX, y: cy + halfH))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            // Three dots
            HStack(spacing: dotSpacing) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(color)
                        .frame(width: dotDiameter, height: dotDiameter)
                }
            }
        }
        .frame(width: w, height: h)
    }

    private var lineWidth: CGFloat { size * 0.135 }
    private var halfH: CGFloat { size * 0.19 }
    private var outerX: CGFloat { size * 0.29 }
    private var tipX: CGFloat { size * 0.46 }
    private var dotDiameter: CGFloat { size * 0.135 }
    private var dotSpacing: CGFloat { size * 0.05 }
}

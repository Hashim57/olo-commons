import SwiftUI

/// How Olo is feeling. The same four moods as the character on heliusnetwork.com.
enum OloMood: String, Codable, Hashable {
    case idle, thinking, happy, unsure
}

/// Olo, the character: a light blue nucleus with eyes, inside two orbit rings. Drawn from plain
/// shapes so the same view works in the app, in the widget and in the Dynamic Island.
/// `animated` runs the float, the blink and the orbiting electrons; widgets pass false.
struct OloFace: View {
    var mood: OloMood = .idle
    var size: CGFloat = 120
    var animated: Bool = true
    /// Where the eyes look, each axis from -1 to 1.
    var look: CGSize = .zero

    static let blue = Color(red: 0.56, green: 0.82, blue: 1.0)

    var body: some View {
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    figure(t: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                figure(t: 0)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Olo")
    }

    private func figure(t: Double) -> some View {
        let s = size
        let body = s * 0.58
        let speed = mood == .thinking ? 2.6 : 1.0
        let floatY: CGFloat = animated ? CGFloat(sin(t * 1.7)) * s * 0.035 : 0
        let blink = animated && (t.truncatingRemainder(dividingBy: 4.6) > 4.45)
        return ZStack {
            // the ring behind the body
            Ellipse().stroke(Color.primary.opacity(0.35), lineWidth: max(1, s * 0.016))
                .frame(width: s * 0.98, height: s * 0.36).rotationEffect(.degrees(38))
            Ellipse().stroke(Color.primary, lineWidth: max(1, s * 0.02))
                .frame(width: s * 0.98, height: s * 0.36).rotationEffect(.degrees(-24))
            // the body
            Circle().fill(OloFace.blue)
                .overlay(Circle().stroke(Color.primary, lineWidth: max(1.2, s * 0.028)))
                .frame(width: body, height: body)
            eyes(body: body, blink: blink)
            mouth(body: body)
            // electrons
            electron(t: t * speed, tilt: -24, radiusX: s * 0.49, radiusY: s * 0.18, dot: s * 0.085, filled: true)
            electron(t: -t * speed * 0.7 + 2, tilt: 38, radiusX: s * 0.49, radiusY: s * 0.18, dot: s * 0.07, filled: false)
        }
        .offset(y: floatY)
    }

    private func eyes(body: CGFloat, blink: Bool) -> some View {
        let w = body * 0.22, h = body * (mood == .happy ? 0.12 : 0.28)
        let dx = max(-1, min(1, look.width)) * w * 0.2
        let dy = max(-1, min(1, look.height)) * h * 0.2 + (mood == .thinking ? -h * 0.18 : 0)
        return HStack(spacing: body * 0.16) {
            ForEach(0..<2, id: \.self) { i in
                ZStack {
                    Ellipse().fill(Color.white).overlay(Ellipse().stroke(Color.black, lineWidth: max(1, body * 0.03)))
                    if mood != .happy {
                        Ellipse().fill(Color.black).frame(width: w * 0.46, height: h * 0.46).offset(x: dx, y: dy)
                    }
                }
                .frame(width: w, height: (mood == .unsure && i == 1) ? h * 0.7 : h)
                .scaleEffect(x: 1, y: blink ? 0.1 : 1)
            }
        }
        .offset(y: -body * 0.08)
    }

    private func mouth(body: CGFloat) -> some View {
        let line = max(1, body * 0.035)
        return Group {
            switch mood {
            case .happy:
                Capsule().fill(Color.black).frame(width: body * 0.3, height: body * 0.13)
            case .thinking:
                Circle().stroke(Color.black, lineWidth: line).frame(width: body * 0.09, height: body * 0.09)
            case .unsure:
                Capsule().fill(Color.black).frame(width: body * 0.2, height: line).rotationEffect(.degrees(-8))
            case .idle:
                Circle().trim(from: 0.08, to: 0.42).stroke(Color.black, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .frame(width: body * 0.22, height: body * 0.22).offset(y: -body * 0.06)
            }
        }
        .offset(y: body * 0.2)
    }

    private func electron(t: Double, tilt: Double, radiusX: CGFloat, radiusY: CGFloat, dot: CGFloat, filled: Bool) -> some View {
        let a = animated ? t * 1.9 : 0.6
        let x: Double = cos(a) * Double(radiusX)
        let y: Double = sin(a) * Double(radiusY)
        let r: Double = tilt * Double.pi / 180
        let cr: Double = cos(r)
        let sr: Double = sin(r)
        let px = CGFloat(x * cr - y * sr)
        let py = CGFloat(x * sr + y * cr)
        return Circle().fill(filled ? Color.primary : OloFace.blue)
            .overlay(Circle().stroke(Color.primary, lineWidth: max(1, dot * 0.2)))
            .frame(width: dot, height: dot)
            .offset(x: px, y: py)
    }
}

import SwiftUI

/// The Helius atom (docs/HELIUS_ATOM.md): a glowing nucleus, three orbits with an
/// electron each, and a network of eight nodes (Olo, Zeus, Helius and five more)
/// growing around it. Drawn with Canvas every frame, so it is crisp at any size and
/// costs nothing to ship. It is decoration: it never blocks input.
struct HeliusAtomView: View {
    enum Mode {
        /// The full build up (about 5 s), then the idle loop. A click skips to idle.
        case launch
        /// Everything in, electrons moving, labels shown.
        case idle
        /// The 56 pt version: network built, electrons moving, no labels.
        case loader
    }

    var mode: Mode
    var size: CGFloat = 220
    /// Draws the dark disc the atom was designed on (#05070D); off when the surface is already dark.
    var showsSurface: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var skipped = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, canvasSize in
                let t = context.date.timeIntervalSince(start)
                HeliusAtomDrawing.draw(&ctx, size: canvasSize, time: t, mode: mode, buildsUp: mode == .launch && !skipped,
                                       reduceMotion: reduceMotion, showsSurface: showsSurface)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture { skipped = true }
        .allowsHitTesting(mode == .launch)
        .accessibilityLabel(mode == .loader ? "Checking the answer" : "The Helius atom: Olo, checked by Zeus, learning on WEBOCTA")
    }
}

/// The geometry and colour of docs/HELIUS_ATOM.md, in a unit square scaled to the canvas.
enum HeliusAtomDrawing {
    // Colours (sRGB) from the spec.
    static let surface = Color(red: 0x05 / 255.0, green: 0x07 / 255.0, blue: 0x0D / 255.0)
    static let nucleusCore = Color(red: 1.0, green: 0xB3 / 255.0, blue: 0x47 / 255.0)    // #FFB347
    static let nucleusEdge = Color(red: 1.0, green: 0x7A / 255.0, blue: 0x18 / 255.0)    // #FF7A18
    static let zeusBlue = Color(red: 0x7C / 255.0, green: 0xC7 / 255.0, blue: 1.0)       // #7CC7FF
    static let oloViolet = Color(red: 0x9B / 255.0, green: 0x8C / 255.0, blue: 1.0)      // #9B8CFF
    static let mist = Color(red: 0xC9 / 255.0, green: 0xD1 / 255.0, blue: 0xE3 / 255.0)  // #C9D1E3

    struct Node {
        let angleDegrees: Double
        let label: String?
        let color: Color
        let radius: Double
    }

    /// Eight nodes on a ring of radius 0.44 at irregular, fixed angles (seeded once, by hand).
    static let nodes: [Node] = [
        Node(angleDegrees: 262, label: "Olo", color: oloViolet, radius: 0.024),
        Node(angleDegrees: 311, label: nil, color: mist.opacity(0.7), radius: 0.016),
        Node(angleDegrees: 349, label: nil, color: mist.opacity(0.7), radius: 0.016),
        Node(angleDegrees: 23, label: "Zeus", color: zeusBlue, radius: 0.024),
        Node(angleDegrees: 76, label: nil, color: mist.opacity(0.7), radius: 0.016),
        Node(angleDegrees: 118, label: nil, color: mist.opacity(0.7), radius: 0.016),
        Node(angleDegrees: 157, label: "Helius", color: nucleusCore, radius: 0.024),
        Node(angleDegrees: 209, label: nil, color: mist.opacity(0.7), radius: 0.016),
    ]

    static let ringRadius = 0.44
    static let orbitAngles: [Double] = [0, 60, 120]
    static let electronPeriods: [Double] = [5.2, 6.4, 7.6]
    static let electronStarts: [Double] = [0.3, 2.4, 4.6]
    static let nodeInterval = 0.6
    static let nodeGrow = 0.4
    static let edgeDraw = 0.5
    static let buildDuration = Double(nodes.count - 1) * nodeInterval + nodeGrow + 0.3
    static let pulseInterval = 1.5
    static let rotationPeriod = 90.0
    static let breathPeriod = 2.8

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, time: TimeInterval, mode: HeliusAtomView.Mode,
                     buildsUp: Bool, reduceMotion: Bool, showsSurface: Bool) {
        let full = Double(min(size.width, size.height))
        // Labels sit outside the ring, so the labelled modes leave a margin for them.
        let s = mode == .loader ? full : full * 0.84
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let still = reduceMotion
        // With reduced motion only the nucleus breathes: everything else sits at its final frame.
        let motionTime = still ? 0 : time
        let buildTime = (buildsUp && !still) ? time : buildDuration + 100
        let rotation = still ? 0 : (2 * .pi * motionTime / rotationPeriod)

        func point(_ x: Double, _ y: Double) -> CGPoint {
            // Unit coordinates around the centre, rotated with the whole drawing, scaled to pixels.
            let rx = x * cos(rotation) - y * sin(rotation)
            let ry = x * sin(rotation) + y * cos(rotation)
            return CGPoint(x: centre.x + CGFloat(rx * s), y: centre.y + CGFloat(ry * s))
        }
        func disc(at p: CGPoint, radius: Double) -> Path {
            let r = CGFloat(radius * s)
            return Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        func glow(_ ctx: inout GraphicsContext, at p: CGPoint, radius: Double, color: Color, opacity: Double) {
            let shading = GraphicsContext.Shading.radialGradient(
                Gradient(colors: [color.opacity(opacity), color.opacity(0)]),
                center: p, startRadius: 0, endRadius: CGFloat(radius * s))
            ctx.fill(disc(at: p, radius: radius), with: shading)
        }

        if showsSurface {
            let half = CGFloat(full / 2)
            ctx.fill(Path(ellipseIn: CGRect(x: centre.x - half, y: centre.y - half, width: 2 * half, height: 2 * half)), with: .color(surface))
        }

        // Network: nodes on the ring, each tied to the nucleus and to its two neighbours.
        let nodePositions: [CGPoint] = nodes.map { n in
            let a = n.angleDegrees * .pi / 180
            return point(ringRadius * cos(a), ringRadius * sin(a))
        }
        func appearance(_ i: Int) -> Double {
            // 0 before the node starts to appear, 1 once it is fully in; eased out.
            let local = (buildTime - Double(i) * nodeInterval) / nodeGrow
            let x = min(max(local, 0), 1)
            return 1 - pow(1 - x, 3)
        }
        func edgeProgress(_ i: Int) -> Double {
            let local = (buildTime - Double(i) * nodeInterval) / edgeDraw
            return min(max(local, 0), 1)
        }
        let edgeColor = Color.white.opacity(0.18)
        for i in nodes.indices {
            let p = CGFloat(edgeProgress(i))
            guard p > 0 else { continue }
            var spoke = Path()
            spoke.move(to: centre)
            spoke.addLine(to: CGPoint(x: centre.x + (nodePositions[i].x - centre.x) * p, y: centre.y + (nodePositions[i].y - centre.y) * p))
            ctx.stroke(spoke, with: .color(edgeColor), lineWidth: 1)
            // The ring edge to the previous neighbour draws as this node arrives (the last node closes the ring).
            let prev = (i + nodes.count - 1) % nodes.count
            if i > 0 || edgeProgress(nodes.count - 1) >= 1 {
                var ring = Path()
                ring.move(to: nodePositions[prev])
                let q: CGFloat = i == 0 ? 1 : p
                ring.addLine(to: CGPoint(x: nodePositions[prev].x + (nodePositions[i].x - nodePositions[prev].x) * q,
                                         y: nodePositions[prev].y + (nodePositions[i].y - nodePositions[prev].y) * q))
                ctx.stroke(ring, with: .color(edgeColor), lineWidth: 1)
            }
        }

        // Orbits: ellipses 0.36 by 0.14 at 0, 60 and 120 degrees.
        for a in orbitAngles {
            let angle = a * .pi / 180 + rotation
            var ellipse = Path(ellipseIn: CGRect(x: -0.36 * s, y: -0.14 * s, width: 0.72 * s, height: 0.28 * s))
            ellipse = ellipse.applying(CGAffineTransform(rotationAngle: CGFloat(angle)))
            ellipse = ellipse.applying(CGAffineTransform(translationX: centre.x, y: centre.y))
            ctx.stroke(ellipse, with: .color(.white.opacity(0.25)), lineWidth: 1)
        }

        // Nucleus with its breathing glow.
        let breath = 0.5 + 0.5 * sin(2 * .pi * time / breathPeriod)
        glow(&ctx, at: centre, radius: 0.16 * (0.92 + 0.08 * breath), color: nucleusCore, opacity: 0.35 * (0.8 + 0.2 * breath))
        let core = GraphicsContext.Shading.radialGradient(Gradient(colors: [nucleusCore, nucleusEdge]), center: centre, startRadius: 0, endRadius: CGFloat(0.07 * s))
        ctx.fill(disc(at: centre, radius: 0.07), with: core)

        // Electrons: one per orbit, periods that never line up.
        for (i, a) in orbitAngles.enumerated() {
            let theta = electronStarts[i] + 2 * .pi * motionTime / electronPeriods[i]
            let local = (x: 0.36 * cos(theta), y: 0.14 * sin(theta))
            let angle = a * .pi / 180
            let x = local.x * cos(angle) - local.y * sin(angle)
            let y = local.x * sin(angle) + local.y * cos(angle)
            let p = point(x, y)
            glow(&ctx, at: p, radius: 0.04, color: zeusBlue, opacity: 0.45)
            ctx.fill(disc(at: p, radius: 0.016), with: .color(zeusBlue))
        }

        // Nodes, scaling in one by one, then their labels (kept upright while the drawing turns).
        let labelSize = CGFloat(max(9, s * 0.055))
        for (i, n) in nodes.enumerated() {
            let grown = appearance(i)
            guard grown > 0 else { continue }
            let p = nodePositions[i]
            if n.label != nil {
                glow(&ctx, at: p, radius: n.radius * 2.2 * grown, color: n.color, opacity: 0.35)
            }
            ctx.fill(disc(at: p, radius: n.radius * grown), with: .color(n.color))
            if mode != .loader, grown >= 1, let label = n.label {
                let text = Text(label.uppercased())
                    .font(.system(size: labelSize, weight: .medium, design: .default))
                    .kerning(labelSize * 0.08)
                    .foregroundStyle(mist)
                let resolved = ctx.resolve(text)
                // Place the label just outside the ring, on the far side from the nucleus.
                let dx = p.x - centre.x, dy = p.y - centre.y
                let d = max(sqrt(dx * dx + dy * dy), 0.001)
                let offset = CGFloat((n.radius + 0.045) * s)
                let at = CGPoint(x: p.x + dx / d * offset, y: p.y + dy / d * offset)
                let anchor: UnitPoint = abs(dx) > abs(dy) * 1.5 ? (dx > 0 ? .leading : .trailing) : (dy > 0 ? .top : .bottom)
                ctx.draw(resolved, at: at, anchor: anchor)
            }
        }

        // Once the network is complete, a small light travels out along one edge and back every 1.5 s.
        let complete = buildTime >= buildDuration
        if complete && !still {
            let since = buildsUp ? motionTime - buildDuration : motionTime
            let cycle = Int(floor(since / pulseInterval))
            let phase = (since - Double(cycle) * pulseInterval) / pulseInterval
            // Visit the nodes in a fixed, scrambled order so the light does not simply walk round the ring.
            let order = [0, 3, 6, 1, 4, 7, 2, 5]
            let target = nodePositions[order[((cycle % order.count) + order.count) % order.count]]
            let outward = phase < 0.5 ? phase * 2 : (1 - phase) * 2
            let eased = CGFloat(0.5 - 0.5 * cos(.pi * outward))
            let p = CGPoint(x: centre.x + (target.x - centre.x) * eased, y: centre.y + (target.y - centre.y) * eased)
            glow(&ctx, at: p, radius: 0.03, color: .white, opacity: 0.5)
            ctx.fill(disc(at: p, radius: 0.009), with: .color(.white.opacity(0.8)))
        }
    }
}

/// The words that sit under the atom on the empty state.
struct HeliusAtomCaption: View {
    var body: some View {
        Text("Olo. Checked by Zeus. Learning on WEBOCTA.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

/// The empty state of a conversation with nothing in it yet: the idle atom and its caption.
struct NewConversationEmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            HeliusAtomView(mode: .idle, size: 180)
            HeliusAtomCaption()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

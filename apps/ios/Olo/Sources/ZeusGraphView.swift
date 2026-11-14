import OloKit
import SwiftUI

/// What Zeus knows (zeus.graph): every claim it verified for this person, drawn with Canvas.
/// The same picture as the Mac: a spiral laid out by OloKit's GraphLayout, colour by verdict,
/// size by corroboration, conflicts as thin red lines. Tap a claim for its evidence.
struct ZeusGraphView: View {
    @EnvironmentObject var model: AppModel
    @State private var graph: ZeusGraph?
    @State private var loading = false
    @State private var problem: String?
    @State private var selectedId: String?
    @State private var filter = ""

    /// The layout's own square; the canvas scales it to the screen.
    private static let side: Double = 420

    private var placed: [GraphLayout.Placed] { GraphLayout.place(graph?.nodes ?? [], size: ZeusGraphView.side) }
    private var selected: ClaimNode? { graph?.nodes.first { $0.id == selectedId } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Every claim Zeus has checked for you, with the sources that settled it. A later answer that makes the same claim reuses the verdict instead of checking again. Private to you.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if loading && graph == nil { ProgressView() }
                if let problem { Text(problem).foregroundStyle(.secondary) }
                if let g = graph {
                    if g.isEmpty {
                        Text("Nothing filed yet. Claims are filed when Zeus checks an answer against sources; ask something with Sources on.")
                            .foregroundStyle(.secondary)
                    } else {
                        canvas(g)
                        stats(g)
                        if let n = selected { claimCard(n) } else { Text("Tap a claim to see its evidence.").font(.footnote).foregroundStyle(.secondary) }
                        claimList(g)
                        sourcesList(g)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("What Zeus knows")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func canvas(_ g: ZeusGraph) -> some View {
        let nodes = placed
        let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chosen = selectedId
        return GeometryReader { geo in
            let scale = Double(min(geo.size.width, geo.size.height)) / ZeusGraphView.side
            Canvas { ctx, _ in
                for c in g.conflicts {
                    guard let a = byId[c.a], let b = byId[c.b] else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: a.x * scale, y: a.y * scale))
                    path.addLine(to: CGPoint(x: b.x * scale, y: b.y * scale))
                    ctx.stroke(path, with: .color(Color.red.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                for p in nodes {
                    let r = p.r * scale
                    let rect = CGRect(x: p.x * scale - r, y: p.y * scale - r, width: r * 2, height: r * 2)
                    let colour = ZeusGraphView.colour(p.node.verdict)
                    ctx.fill(Path(ellipseIn: rect), with: .color(colour.opacity(p.id == chosen ? 1 : 0.75)))
                    if p.id == chosen {
                        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(Color.primary), lineWidth: 1.5)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { point in
                guard scale > 0 else { return }
                selectedId = GraphLayout.hit(nodes, x: Double(point.x) / scale, y: Double(point.y) / scale, slop: 10)?.id
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Graph of \(g.nodes.count) claims")
    }

    private func stats(_ g: ZeusGraph) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(g.stats.claims) claims, \(g.stats.evidence) pieces of evidence, \(g.stats.conflicts) conflicts.").font(.subheadline)
            Text("\(g.stats.recalled) answers reused a verdict instead of checking again.").font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                legend("Supported", "supported")
                legend("Contradicted", "contradicted")
                legend("Not covered", "unsupported")
            }
            .font(.caption)
        }
    }

    private func legend(_ label: String, _ verdict: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ZeusGraphView.colour(verdict)).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private func claimCard(_ n: ClaimNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(n.claim).font(.body.weight(.medium)).textSelection(.enabled)
            Text(n.verdict == "unsupported" ? "Not covered" : n.verdict.capitalized).font(.caption.weight(.semibold)).foregroundStyle(ZeusGraphView.colour(n.verdict))
            Text("\(Int((n.confidence * 100).rounded()))% confidence, \(n.supporting) for, \(n.contradicting) against" + (n.hitCount > 0 ? ", reused \(n.hitCount) times" : ""))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(n.evidence.enumerated()), id: \.offset) { _, e in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: e.stance == "contradicts" ? "xmark.circle" : "checkmark.circle")
                        .foregroundStyle(e.stance == "contradicts" ? Color.red : Color.green)
                    VStack(alignment: .leading, spacing: 1) {
                        if let url = URL(string: e.url), LinkPolicy.isSafeExternal(url) {
                            Link(e.title ?? e.domain, destination: url).lineLimit(2).multilineTextAlignment(.leading)
                        } else {
                            Text(e.title ?? e.domain).lineLimit(2)
                        }
                        Text(e.domain).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func claimList(_ g: ZeusGraph) -> some View {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = f.isEmpty ? g.nodes : g.nodes.filter { $0.claim.lowercased().contains(f) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Claims").font(.headline)
            TextField("Filter claims", text: $filter).textFieldStyle(.roundedBorder)
            ForEach(Array(shown.prefix(60))) { n in
                Button { selectedId = n.id } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(ZeusGraphView.colour(n.verdict)).frame(width: 8, height: 8).padding(.top, 6)
                        Text(n.claim).font(.subheadline).lineLimit(3).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(n.supporting + n.contradicting)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(n.id == selectedId ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if shown.count > 60 { Text("Showing the first 60 of \(shown.count).").font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func sourcesList(_ g: ZeusGraph) -> some View {
        if !g.sources.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Source reputations").font(.headline)
                Text("How often each domain has been on the right side of the evidence. Earned, not assumed.").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(g.sources.prefix(30))) { s in
                    HStack {
                        Text(s.domain).font(.subheadline).lineLimit(1)
                        Spacer()
                        ProgressView(value: min(1, max(0, s.reputation))).frame(width: 70)
                        Text("\(Int((s.reputation * 100).rounded()))% of \(s.total)").font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
                    }
                }
            }
        }
    }

    static func colour(_ verdict: String) -> Color {
        switch verdict {
        case "supported": return Color(red: 0.37, green: 0.81, blue: 0.56)
        case "contradicted": return Color(red: 1.0, green: 0.56, blue: 0.56)
        default: return Color(red: 0.91, green: 0.76, blue: 0.48)
        }
    }

    private func load() async {
        guard model.api.token != nil else { problem = "Sign in to see the graph."; return }
        loading = true
        defer { loading = false }
        do {
            graph = try await model.api.zeusGraph()
            problem = nil
        } catch let e as TRPC.RemoteError where e.isNotFound {
            problem = "This server has no graph yet."
        } catch {
            problem = error.localizedDescription
        }
    }
}

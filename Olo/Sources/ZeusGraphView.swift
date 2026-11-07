import SwiftUI
import OloKit

/// What Zeus knows (zeus.graph): every claim it verified for this person, drawn with
/// Canvas. The same picture as the iPhone: a phyllotaxis spiral, colour by verdict, size
/// by corroboration, conflicts as thin red lines. Click a claim for its evidence.
struct ZeusGraphView: View {
    @Environment(AppModel.self) private var model
    @State private var graph: ZeusGraph?
    @State private var loading = false
    @State private var error: String?
    @State private var selectedId: String?
    @State private var filter = ""

    private static let size: CGFloat = 420

    private var placed: [GraphLayout.Placed] { GraphLayout.place(graph?.nodes ?? [], size: Double(ZeusGraphView.size)) }
    private var selected: ClaimNode? { graph?.nodes.first { $0.id == selectedId } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let error { Text(error).foregroundStyle(.secondary) }
                if let g = graph {
                    if g.isEmpty {
                        Text("Nothing filed yet. Claims are filed when Zeus checks an answer against sources; ask something with Search the web on.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(alignment: .top, spacing: 24) {
                            canvas(g)
                            VStack(alignment: .leading, spacing: 14) {
                                stats(g)
                                if let n = selected { claimCard(n) } else { Text("Click a claim to see its evidence.").font(.callout).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        claimList(g)
                        sourcesList(g)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What Zeus knows").font(.largeTitle.weight(.semibold))
                Text("Every claim Zeus has checked for you, with the sources that settled it. A later answer that makes the same claim reuses the verdict instead of checking again. Private to you.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button("Refresh") { Task { await load() } }.disabled(loading)
        }
    }

    private func canvas(_ g: ZeusGraph) -> some View {
        let nodes = placed
        let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Canvas { ctx, size in
            let scale = min(size.width, size.height) / ZeusGraphView.size
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
                ctx.fill(Path(ellipseIn: rect), with: .color(colour.opacity(p.id == selectedId ? 1 : 0.75)))
                if p.id == selectedId {
                    ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.primary), lineWidth: 1.5)
                }
            }
        }
        .frame(width: ZeusGraphView.size, height: ZeusGraphView.size)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .onTapGesture { point in
            selectedId = GraphLayout.hit(nodes, x: Double(point.x), y: Double(point.y))?.id
        }
        .accessibilityLabel("Graph of \(g.nodes.count) claims")
    }

    private func stats(_ g: ZeusGraph) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(g.stats.claims) claims, \(g.stats.evidence) pieces of evidence, \(g.stats.conflicts) conflicts.")
            Text("\(g.stats.recalled) answers reused a verdict instead of checking again.").foregroundStyle(.secondary)
            HStack(spacing: 12) {
                legend("Supported", .supported)
                legend("Contradicted", .contradicted)
                legend("Not covered", .unsupported)
            }
            .font(.caption)
        }
        .font(.callout)
    }

    private func legend(_ label: String, _ verdict: Verdict) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ZeusGraphView.colour(verdict.rawValue)).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private enum Verdict: String { case supported, contradicted, unsupported }

    private func claimCard(_ n: ClaimNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(n.claim).font(.body.weight(.medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(n.verdict == "unsupported" ? "Not covered" : n.verdict.capitalized).foregroundStyle(ZeusGraphView.colour(n.verdict))
                Text("\(Int((n.confidence * 100).rounded()))% confidence")
                Text("\(n.supporting) for, \(n.contradicting) against")
                if let v = n.volatility { Text(v) }
                if n.hitCount > 0 { Text("reused \(n.hitCount)\u{00D7}") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !n.evidence.isEmpty {
                ForEach(Array(n.evidence.enumerated()), id: \.offset) { _, e in
                    HStack(spacing: 6) {
                        Image(systemName: e.stance == "contradicts" ? "xmark.circle" : "checkmark.circle")
                            .foregroundStyle(e.stance == "contradicts" ? Color.red : Color.green)
                        if let url = URL(string: e.url), LinkPolicy.isSafeExternal(url) {
                            Link(e.title ?? e.domain, destination: url).lineLimit(1)
                        } else {
                            Text(e.title ?? e.domain).lineLimit(1)
                        }
                        Text(e.domain).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func claimList(_ g: ZeusGraph) -> some View {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = f.isEmpty ? g.nodes : g.nodes.filter { $0.claim.lowercased().contains(f) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Claims").font(.headline)
                Spacer()
                TextField("Filter claims", text: $filter).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            ForEach(shown.prefix(60)) { n in
                Button { selectedId = n.id } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(ZeusGraphView.colour(n.verdict)).frame(width: 8, height: 8).padding(.top, 5)
                        Text(n.claim).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
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

    private func sourcesList(_ g: ZeusGraph) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !g.sources.isEmpty {
                Text("Source reputations").font(.headline)
                Text("How often each domain has been on the right side of the evidence. Earned, not assumed.").font(.caption).foregroundStyle(.secondary)
                ForEach(g.sources.prefix(30)) { s in
                    HStack {
                        Text(s.domain).lineLimit(1)
                        Spacer()
                        ProgressView(value: min(1, max(0, s.reputation))).frame(width: 120).controlSize(.small)
                        Text("\(Int((s.reputation * 100).rounded()))% of \(s.total)").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    }
                    .font(.callout)
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
        guard model.canReachCloud, model.api.token != nil else { error = "Sign in and connect to see the graph."; return }
        loading = true
        defer { loading = false }
        do { graph = try await model.api.zeusGraph(); error = nil }
        catch let e as TRPC.RemoteError where e.isNotFound { error = "This server has no graph yet." }
        catch { self.error = error.localizedDescription }
    }
}

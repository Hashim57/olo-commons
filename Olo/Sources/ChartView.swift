import Charts
import SwiftUI
import OloKit

/// An inline chart from a ```chart block, drawn with Swift Charts from the same strict
/// spec the web (SVG) and iPhone (react-native-svg) draw: bars or lines, up to 24 points
/// and 4 series, the same series colours.
struct InlineChartView: View {
    let spec: ChartSpec

    private struct Point: Identifiable {
        let id: String
        let series: String
        let x: String
        let y: Double
    }

    private var points: [Point] {
        var out: [Point] = []
        for s in spec.series {
            for (i, v) in s.values.enumerated() where i < spec.x.count {
                out.append(Point(id: "\(s.name)-\(i)", series: s.name, x: spec.x[i], y: v))
            }
        }
        return out
    }

    private var colours: KeyValuePairs<String, Color> {
        // KeyValuePairs cannot be built in a loop, so the four slots are written out.
        let names = spec.series.map(\.name)
        let c = ChartSpec.seriesColours.map { InlineChartView.colour($0) }
        switch names.count {
        case 1: return [names[0]: c[0]]
        case 2: return [names[0]: c[0], names[1]: c[1]]
        case 3: return [names[0]: c[0], names[1]: c[1], names[2]: c[2]]
        default: return [names[0]: c[0], names[1]: c[1], names[2]: c[2], names[3]: c[3]]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = spec.title { Text(t).font(.callout.weight(.medium)) }
            chart
                .frame(height: 220)
                .chartForegroundStyleScale(colours)
                .chartLegend(spec.series.count > 1 ? .visible : .hidden)
                .chartYAxisLabel(spec.y ?? "")
            Text("Drawn from the figures in the answer; check them against the sources like any other claim.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(spec.title ?? "Chart")
    }

    @ViewBuilder
    private var chart: some View {
        if spec.type == "line" {
            Chart(points) { p in
                LineMark(x: .value("Category", p.x), y: .value(spec.y ?? "Value", p.y))
                    .foregroundStyle(by: .value("Series", p.series))
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Category", p.x), y: .value(spec.y ?? "Value", p.y))
                    .foregroundStyle(by: .value("Series", p.series))
            }
        } else {
            Chart(points) { p in
                BarMark(x: .value("Category", p.x), y: .value(spec.y ?? "Value", p.y))
                    .foregroundStyle(by: .value("Series", p.series))
                    .position(by: .value("Series", p.series))
            }
        }
    }

    /// "#5ec8a6" as a Color.
    static func colour(_ hex: String) -> Color {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .accentColor }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// An answer's text with its charts in place of the ```chart blocks.
struct AnswerBody: View {
    let content: String
    let render: (String) -> Text

    var body: some View {
        let segments = ChartBlocks.segments(of: content)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let t): render(t).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                case .chart(let spec): InlineChartView(spec: spec)
                case .broken: Label("A chart in this answer could not be drawn; its figures did not add up to a chart.", systemImage: "chart.bar.xaxis").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

import Foundation

/// An inline chart: an answer can carry a ```chart block holding a small JSON spec.
/// Parsed strictly, as client/src/lib/chartSpec.ts does (a chart that lies about its
/// data is worse than a table), so the Mac draws exactly what the web and iPhone draw.
public struct ChartSpec: Equatable, Sendable {
    public struct Series: Equatable, Sendable {
        public var name: String
        public var values: [Double]
        public init(name: String, values: [Double]) { self.name = name; self.values = values }
    }

    /// "bar" or "line".
    public var type: String
    public var title: String?
    /// Category labels along the x axis.
    public var x: [String]
    public var series: [Series]
    /// Unit or label for the y axis, such as "£m" or "%".
    public var y: String?

    public static let maxPoints = 24
    public static let maxSeries = 4
    /// The same series colours as the web (hex).
    public static let seriesColours = ["#5ec8a6", "#e0a657", "#8fb4ff", "#e58fcf"]

    public init(type: String, title: String? = nil, x: [String], series: [Series], y: String? = nil) {
        self.type = type; self.title = title; self.x = x; self.series = series; self.y = y
    }

    /// Strict parse. Nil for anything that is not a drawable chart.
    public static func parse(_ raw: String) -> ChartSpec? {
        guard let data = raw.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let spec) = value else { return nil }
        let type: String
        switch spec["type"]?.stringValue {
        case "line": type = "line"
        case "bar": type = "bar"
        default: return nil
        }
        guard case .array(let xs)? = spec["x"], xs.count >= 2, xs.count <= maxPoints else { return nil }
        let x = xs.map { String(label($0).prefix(24)) }
        guard case .array(let items)? = spec["series"], items.count >= 1, items.count <= maxSeries else { return nil }
        var series: [Series] = []
        for item in items {
            guard case .object(let entry) = item, case .array(let raws)? = entry["values"], raws.count == x.count else { return nil }
            var values: [Double] = []
            for r in raws {
                guard let v = number(r), v.isFinite else { return nil }
                values.append(v)
            }
            let raw = entry["name"].map(label) ?? ""
            let name = raw.isEmpty ? "Series \(series.count + 1)" : raw
            series.append(Series(name: String(name.prefix(40)), values: values))
        }
        return ChartSpec(type: type, title: spec["title"]?.stringValue.map { String($0.prefix(80)) }, x: x, series: series,
                         y: spec["y"]?.stringValue.map { String($0.prefix(20)) })
    }

    private static func label(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return ""
        }
    }

    private static func number(_ v: JSONValue) -> Double? {
        switch v {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var minValue: Double { min(0, series.flatMap(\.values).min() ?? 0) }
    public var maxValue: Double { max(0, series.flatMap(\.values).max() ?? 0) }
}

/// Splits an answer into prose and the charts between it.
public enum ChartSegment: Equatable, Sendable {
    case text(String)
    case chart(ChartSpec)
    /// A ```chart block that did not parse: shown as a note, never as a wrong picture.
    case broken

    public var text: String? { if case .text(let t) = self { return t }; return nil }
}

public enum ChartBlocks {
    /// Pulls ```chart blocks out of an answer; the text around them is kept in order.
    public static func segments(of content: String) -> [ChartSegment] {
        guard content.contains("```chart") else { return [.text(content)] }
        guard let re = try? NSRegularExpression(pattern: "```chart[ \\t]*\\n([\\s\\S]*?)```", options: []) else { return [.text(content)] }
        let ns = content as NSString
        var out: [ChartSegment] = []
        var cursor = 0
        for m in re.matches(in: content, options: [], range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { out.append(.text(before)) }
            let body = ns.substring(with: m.range(at: 1))
            if let spec = ChartSpec.parse(body) { out.append(.chart(spec)) } else { out.append(.broken) }
            cursor = m.range.location + m.range.length
        }
        let rest = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(.text(rest)) }
        return out.isEmpty ? [.text(content)] : out
    }

    /// The answer with every chart block removed, for sentence splitting and copying.
    public static func textOnly(_ content: String) -> String {
        segments(of: content).compactMap(\.text).joined(separator: "\n\n")
    }

    /// A readable step for the y axis: 1, 2 or 5 times a power of ten.
    public static func niceStep(_ range: Double, target: Double = 4) -> Double {
        guard range > 0 else { return 1 }
        let rough = range / target
        let magnitude = pow(10, floor(log10(rough)))
        let residual = rough / magnitude
        let factor: Double = residual <= 1 ? 1 : (residual <= 2 ? 2 : (residual <= 5 ? 5 : 10))
        return factor * magnitude
    }

    /// "1.5k", "2M", "12", "0.25": the same tick labels as the web.
    public static func formatTick(_ value: Double) -> String {
        let a = abs(value)
        if a >= 1_000_000 { return trimZeros(String(format: "%.1f", value / 1_000_000)) + "M" }
        if a >= 1_000 { return trimZeros(String(format: "%.1f", value / 1_000)) + "k" }
        if a >= 100 { return String(format: "%.0f", value) }
        if a >= 1 { return trimZeros(String(format: "%.1f", value)) }
        return trimZeros(String(format: "%.2f", value))
    }

    static func trimZeros(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
}

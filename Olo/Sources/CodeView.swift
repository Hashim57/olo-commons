import SwiftUI
import OloKit

/// Colours and symbols for an issue's severity, the same in the code view and the Olo pane.
enum SeverityStyle {
    static func color(_ severity: String) -> Color {
        switch severity {
        case "error": return .red
        case "warning": return .orange
        default: return .blue
        }
    }

    static func symbol(_ severity: String) -> String {
        switch severity {
        case "error": return "xmark.octagon.fill"
        case "warning": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    static func rank(_ severity: String) -> Int {
        switch severity { case "error": return 0; case "warning": return 1; default: return 2 }
    }
}

/// A read-only view of a source file: line numbers, the lines Olo flagged tinted by severity
/// (the selected issue more strongly), and a scroll to the line an issue names.
struct CodeView: View {
    private let lines: [String]
    private let marks: [Int: String]
    private let selected: ClosedRange<Int>?
    private let jumpLine: Int?
    private let jumpToken: Int
    private let gutterWidth: CGFloat

    init(text: String, issues: [CodeIssue], jumpLine: Int?, jumpToken: Int, selectedIssueId: String?) {
        var parsed = SourceText(text).lines.map { $0.replacingOccurrences(of: "\t", with: "    ") }
        if parsed.isEmpty { parsed = [""] }
        var found: [Int: String] = [:]
        var chosen: ClosedRange<Int>?
        for issue in issues {
            let low = max(1, issue.line)
            let high = min(max(low, issue.endLine), parsed.count)
            guard low <= high else { continue }
            if issue.id == selectedIssueId { chosen = low...high }
            for n in low...high {
                if let existing = found[n], SeverityStyle.rank(existing) <= SeverityStyle.rank(issue.severity) { continue }
                found[n] = issue.severity
            }
        }
        self.lines = parsed
        self.marks = found
        self.selected = chosen
        self.jumpLine = jumpLine
        self.jumpToken = jumpToken
        self.gutterWidth = CGFloat(max(3, String(parsed.count).count)) * 8 + 6
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            row(number: index + 1, line: line)
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(minWidth: geo.size.width, alignment: .leading)
                }
                .onChange(of: jumpToken) { scroll(proxy) }
                .onAppear { scroll(proxy) }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let line = jumpLine else { return }
        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(min(max(line, 1), lines.count), anchor: .center) }
    }

    private func row(number: Int, line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(String(number))
                .foregroundStyle(.secondary)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 10)
            Text(line.isEmpty ? " " : line)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint(for: number))
        .id(number)
    }

    private func tint(for line: Int) -> Color {
        guard let severity = marks[line] else { return .clear }
        let strong = selected?.contains(line) ?? false
        return SeverityStyle.color(severity).opacity(strong ? 0.30 : 0.13)
    }
}

import SwiftUI
import OloKit

/// A unified diff of Olo's proposed change: old and new line numbers, removed lines in red,
/// added lines in green, long unchanged runs folded into one line.
struct DiffView: View {
    let rows: [DiffRow]

    var body: some View {
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        DiffRowView(row: row)
                    }
                }
                .padding(.vertical, 4)
                .frame(minWidth: geo.size.width, alignment: .leading)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct DiffRowView: View {
    let row: DiffRow

    private var marker: String {
        switch row.kind {
        case .added: return "+"
        case .removed: return "-"
        default: return " "
        }
    }

    private var tint: Color {
        switch row.kind {
        case .added: return Color.green.opacity(0.16)
        case .removed: return Color.red.opacity(0.16)
        default: return Color.clear
        }
    }

    var body: some View {
        if row.kind == .skipped {
            Text("\(row.skipped) unchanged line\(row.skipped == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
        } else {
            HStack(spacing: 0) {
                Text(row.oldLine.map { String($0) } ?? "")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                Text(row.newLine.map { String($0) } ?? "")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                Text(marker)
                    .foregroundStyle(row.kind == .added ? Color.green : (row.kind == .removed ? Color.red : Color.secondary))
                    .frame(width: 18)
                Text(row.text.isEmpty ? " " : row.text.replacingOccurrences(of: "\t", with: "    "))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.trailing, 8)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint)
        }
    }
}

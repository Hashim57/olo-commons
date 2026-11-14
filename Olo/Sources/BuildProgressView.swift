import SwiftUI
import OloKit

/// A background build, as it happens: every step the server recorded with a tick, a spinner on the
/// one it is doing (the writing step counts up as the file arrives), the time since it started and
/// the percentage, and once it is done who wrote the file ("Answered by Olo", or Olo's backup model
/// via its provider). The same card as the web (client/src/components/BuildProgress.tsx in olo-web).
struct BuildProgressView: View {
    let job: BuildJob
    let turnId: UUID
    @Environment(AppModel.self) private var model
    @State private var showAll = false

    private var rows: [BuildTimelineRow] { job.timeline }
    private var visible: [BuildTimelineRow] { showAll || !job.isRunning ? rows : Array(rows.suffix(4)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if job.isRunning {
                ProgressView(value: Double(max(2, min(100, job.progress))), total: 100)
                    .progressViewStyle(.linear)
            }
            if rows.count > visible.count {
                Button { showAll = true } label: {
                    Label("\(rows.count - visible.count) earlier \(rows.count - visible.count == 1 ? "step" : "steps")", systemImage: "chevron.down")
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(visible) { row in step(row) }
            if job.status == "failed" {
                Text(job.error ?? "The build failed.").font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if job.canRetry {
                Button { model.retryBackgroundBuild(tid: turnId) } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            if let line = job.finishedAnsweredBy?.line {
                // Said plainly, not as a warning: a backup writer finishing the file is not a fault.
                Text(line)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if job.isRunning {
                Text("This runs on the server. You can close Olo and come back to it.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(borderColor))
    }

    private var borderColor: Color {
        switch job.status {
        case "succeeded": return .green.opacity(0.4)
        case "failed": return .red.opacity(0.45)
        default: return Color(nsColor: .separatorColor)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Group {
                if job.isRunning { ProgressView().controlSize(.small) }
                else if job.status == "succeeded" { Image(systemName: "checkmark").foregroundStyle(.green) }
                else { Image(systemName: "exclamationmark.circle").foregroundStyle(.red) }
            }
            .frame(width: 18, height: 18)
            Text(job.headline).font(.callout.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 10) {
                    if let e = job.elapsed(now: job.isRunning ? context.date : lastStepDate ?? context.date) {
                        Text(BuildTimelineRow.clock(e)).help("Time since the build started")
                    }
                    if job.isRunning { Text("\(job.progress)%") }
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if job.isRunning {
                Button("Cancel") { model.cancelBackgroundBuild(tid: turnId) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private var lastStepDate: Date? {
        guard let s = job.steps.last?.at else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private func step(_ row: BuildTimelineRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch row.state {
                case .current: ProgressView().controlSize(.mini)
                case .failed: Image(systemName: "xmark").foregroundStyle(.red)
                case .done:
                    if row.notice { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    else { Image(systemName: "checkmark").foregroundStyle(.green) }
                }
            }
            .font(.caption).frame(width: 14)
            Text(row.label)
                .font(.callout)
                .foregroundStyle(row.state == .current ? Color.primary : row.state == .failed ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let o = row.offset {
                Text(BuildTimelineRow.clock(o)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
    }
}

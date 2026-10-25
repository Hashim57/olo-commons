import SwiftUI
import OloKit

/// Messages used of the plan's limit (and analyses), from billing.entitlement: the web's
/// Credits section and the iPhone's Credits screen, in one line. Nothing is shown until the
/// server has answered, and nothing for an anonymous workspace, whose allowance the server
/// counts by itself.
struct UsageMeter: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        if let e = model.entitlement, model.user?.email != nil {
            VStack(alignment: .leading, spacing: 4) {
                if e.messageLimit > 0 {
                    ProgressView(value: Double(min(e.messagesUsed, e.messageLimit)), total: Double(e.messageLimit))
                        .progressViewStyle(.linear).controlSize(.small)
                }
                Text(line(e)).font(.caption2).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
                if !compact, e.computeLimit > 0 {
                    Text("\(e.computeUsed) of \(e.computeLimit) analyses used.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .help(e.isFree ? BillingText.freePlan : "Olo \(e.planName): the same allowance on the web and your iPhone.")
        }
    }

    private func line(_ e: Entitlement) -> String {
        if e.messageLimit > 0 {
            return "\(e.messagesUsed.formatted()) of \(e.messageLimit.formatted()) messages used" + (e.isFree ? " today" : " this month") + (compact ? "" : " on Olo \(e.planName).")
        }
        return "Olo \(e.planName)"
    }
}

/// "about N% of the context used": the estimate under the composer, amber at 70 percent,
/// red at 90, with the suggestion the web makes at that point.
struct ContextGaugeView: View {
    let reading: ContextGauge.Reading

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(colour).frame(width: 6, height: 6)
            Text(reading.suggestSummary ? reading.line + ". Long thread: a new conversation answers faster" : reading.line)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption2)
        .foregroundStyle(reading.level == .ok ? Color.secondary : colour)
        .help("An estimate of how much of the model's window the thread fills: the last turns, four characters to a token.")
    }

    private var colour: Color {
        switch reading.level {
        case .ok: return .green
        case .warn: return .orange
        case .danger: return .red
        }
    }
}

/// Settings > Account: the meter in full.
struct UsageSection: View {
    var body: some View {
        Section("Usage") {
            UsageMeter(compact: false)
        }
    }
}

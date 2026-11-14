import SwiftUI
import OloKit

/// Analyses (compute.*): the background jobs started with "Analyse" in the composer, with
/// their stages and progress, and a Cancel for the ones still running. The result of a job
/// lands in the conversation it was started from.
struct JobsView: View {
    @Environment(AppModel.self) private var model
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Analyses").font(.largeTitle.weight(.semibold))
                    Text("Heavier questions run as background jobs on helius-olo.io: planned, split into parallel tasks and merged. Start one with Analyse in the composer menu. Each plan includes a number of analyses a month.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("Refresh") { Task { await refresh() } }.disabled(loading)
                        if loading { ProgressView().controlSize(.small) }
                        UsageMeter(compact: false)
                    }
                }
                if model.jobs.isEmpty && !loading {
                    Text("No analyses yet.").foregroundStyle(.secondary)
                }
                ForEach(model.jobs) { jobCard($0) }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refresh() }
        .task(id: model.jobs.contains(where: { $0.isRunning })) { await poll() }
    }

    private func jobCard(_ j: ComputeJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(j.prompt).font(.callout.weight(.medium)).lineLimit(2)
                Spacer()
                if j.isRunning {
                    Button(j.cancelRequested ? "Cancelling..." : "Cancel") { Task { await model.cancelJob(j.id) } }
                        .controlSize(.small).disabled(j.cancelRequested)
                }
            }
            if j.isRunning { ProgressView(value: j.fraction).controlSize(.small) }
            Text(j.statusLine).font(.caption).foregroundStyle(j.status == "failed" ? Color.red : Color.secondary)
            if !j.stages.isEmpty {
                HStack(spacing: 8) {
                    ForEach(j.stages) { s in
                        Label(s.label, systemImage: stageSymbol(s.status)).font(.caption2)
                            .foregroundStyle(s.status == "failed" ? Color.red : (s.status == "pending" ? Color.secondary : Color.primary))
                    }
                }
            }
            if let cid = j.conversationId {
                Button("Open Conversation") { model.openServerConversation(cid) }.buttonStyle(.link).font(.caption)
            }
            if let r = j.result, j.status == "succeeded" {
                DisclosureGroup("Result") {
                    Text(r).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stageSymbol(_ status: String) -> String {
        switch status {
        case "done": return "checkmark.circle"
        case "running": return "circle.dotted"
        case "failed": return "xmark.circle"
        default: return "circle"
        }
    }

    private func refresh() async {
        loading = true
        await model.refreshJobs()
        loading = false
    }

    /// While a job runs, refresh every three seconds.
    private func poll() async {
        while model.jobs.contains(where: { $0.isRunning }) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            await model.refreshJobs()
        }
    }
}

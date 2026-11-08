import AppKit
import SwiftUI
import OloKit

/// Watching (monitors.*): the claims Olo re-checks on a schedule, what changed since the
/// person last looked, a check now, the webhook, and the evidence file. A watch is
/// created from an answer (Watch in the verification box), as on the web and iPhone.
struct MonitorsView: View {
    @Environment(AppModel.self) private var model
    @State private var monitors: [Monitor] = []
    @State private var hook: MonitorHook?
    @State private var loading = false
    @State private var checking: String?
    @State private var note: String?
    @State private var error: String?

    private var changed: [Monitor] { monitors.filter { $0.hasChanged } }
    private var steady: [Monitor] { monitors.filter { !$0.hasChanged } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let error { Text(error).foregroundStyle(.secondary) }
                if monitors.isEmpty && error == nil && !loading {
                    Text("Nothing watched yet. Under a checked answer, Watch asks Olo to re-check its claims and tell you when the evidence moves.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !changed.isEmpty { changedSection }
                if !steady.isEmpty { steadySection }
                hookSection
                evidenceSection
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Watching").font(.largeTitle.weight(.semibold))
            Text("A monitor tells you when something stops being true. Each watched claim is re-checked against fresh sources on its own schedule, and a change is a nudge here and on your other devices.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(checking == "all" ? "Checking..." : "Check Everything Now") { Task { await check(nil) } }
                    .disabled(checking != nil || monitors.isEmpty)
                Button("Refresh") { Task { await load() } }.disabled(loading)
                if loading { ProgressView().controlSize(.small) }
                if let n = note { Text(n).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var changedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Changed since you last looked").font(.headline).foregroundStyle(.orange)
            ForEach(changed) { m in
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.claim).fixedSize(horizontal: false, vertical: true)
                    if let n = m.changeNote { Text(n).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    HStack {
                        Button("Got It") { Task { await acknowledge(m) } }.controlSize(.small)
                        Button("Stop Watching") { Task { await unwatch(m) } }.controlSize(.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var steadySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Watched").font(.headline)
            ForEach(steady) { m in
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.claim).fixedSize(horizontal: false, vertical: true)
                    Text("\(m.baselineVerdict == "unsupported" ? "Not covered" : m.baselineVerdict.capitalized) when the watch began; checked \(m.intervalLine)" + (m.lastChecked.map { ", last \(String($0.prefix(10)))" } ?? "") + ".")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(checking == m.id ? "Checking..." : "Check Now") { Task { await check(m.id) } }.controlSize(.small).disabled(checking != nil)
                        Button("Stop Watching") { Task { await unwatch(m) } }.controlSize(.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var hookSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trigger from outside").font(.headline)
            Text("A POST to this address re-checks your watched claims this minute: from a calendar, a script or another service. Anyone holding it can trigger a check, nothing more; rotate it if it leaks.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let h = hook {
                Text(h.fullURL(base: model.api.base).absoluteString).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                Text("Fired \(h.fires) time\(h.fires == 1 ? "" : "s")" + (h.lastFired.map { ", last \(String($0.prefix(10)))" } ?? "") + ".").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(h.fullURL(base: model.api.base).absoluteString, forType: .string)
                        note = "Hook address copied."
                    }
                    Button("Rotate") { Task { await rotateHook() } }
                    Button("Revoke", role: .destructive) { Task { try? await model.api.revokeMonitorHook(); hook = nil } }
                }
                .controlSize(.small)
            } else {
                Button("Create a Hook Address") { Task { await rotateHook() } }.controlSize(.small)
            }
        }
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Evidence file").font(.headline)
            Text("Every claim Zeus verified for you, with its sources and when it was checked, as a page to keep or send. Saved as HTML and opened in your browser, where Print makes a PDF.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Save Evidence File...") { Task { await saveEvidence() } }.controlSize(.small)
        }
    }

    // MARK: Actions

    private func load() async {
        guard model.canReachCloud, model.api.token != nil else { error = "Sign in and connect to see what is watched."; return }
        loading = true
        defer { loading = false }
        do {
            monitors = try await model.api.listMonitors()
            error = nil
        } catch let e as TRPC.RemoteError where e.isNotFound {
            error = "This server has no monitors yet."
        } catch {
            self.error = error.localizedDescription
        }
        hook = try? await model.api.monitorHook()
    }

    private func check(_ id: String?) async {
        checking = id ?? "all"
        defer { checking = nil }
        do {
            let result = try await model.api.checkMonitorsNow(monitorId: id)
            note = result.summary
            await load()
        } catch {
            note = "Could not check: \(error.localizedDescription)"
        }
    }

    private func acknowledge(_ m: Monitor) async {
        do { try await model.api.acknowledgeChange(monitorId: m.id); await load() }
        catch { note = "Could not acknowledge: \(error.localizedDescription)" }
    }

    private func unwatch(_ m: Monitor) async {
        do { try await model.api.unwatch(monitorId: m.id); monitors.removeAll { $0.id == m.id } }
        catch { note = "Could not stop watching: \(error.localizedDescription)" }
    }

    private func rotateHook() async {
        do { hook = try await model.api.rotateMonitorHook() }
        catch { note = "Could not make a hook: \(error.localizedDescription)" }
    }

    private func saveEvidence() async {
        do {
            let file = try await model.api.evidenceFile()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "olo-evidence-file.html"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try Data(file.html.utf8).write(to: url, options: [.atomic])
            note = "Saved \(file.claimCount) claims from \(file.sourceCount) sources."
            NSWorkspace.shared.open(url)
        } catch {
            note = "Could not build the evidence file: \(error.localizedDescription)"
        }
    }
}

import AppKit
import SwiftUI
import OloKit

/// Connected accounts (connectors.*): Google first, Gmail and Calendar read only. Connect
/// opens Google's consent page in the browser; the callback lands on helius-olo.io, which
/// sends the browser to olo://connected, and this panel polls connectors.list until the
/// account appears. Tokens never reach the Mac.
struct ConnectorsView: View {
    @Environment(AppModel.self) private var model
    @State private var list: ConnectorList?
    @State private var loading = false
    @State private var error: String?
    @State private var note: String?
    @State private var waiting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connectors").font(.largeTitle.weight(.semibold))
                    Text("Accounts Olo may read on your behalf when you ask about them: your mail or your calendar, say. Read only. Nothing is read until a question calls for it, and every reply says what was used.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error { Text(error).foregroundStyle(.secondary) }
                if let l = list { google(l) }
                HStack(spacing: 12) {
                    Button("Refresh") { Task { await load() } }.disabled(loading)
                    if loading || waiting { ProgressView().controlSize(.small) }
                    if waiting { Text("Waiting for Google to finish in your browser...").font(.caption).foregroundStyle(.secondary) }
                    if let n = note { Text(n).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
    }

    private func google(_ l: ConnectorList) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "envelope.badge").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google").font(.headline)
                    if let g = l.google {
                        Text(g.account).font(.callout)
                        Text(g.scopesLine).font(.caption).foregroundStyle(.secondary)
                        if let broken = g.brokenReason { Text("Needs reconnecting: \(broken)").font(.caption).foregroundStyle(.orange) }
                    } else {
                        Text("Gmail and Calendar, read only.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if l.google != nil {
                    Button("Disconnect", role: .destructive) { Task { await disconnect() } }
                    if l.google?.brokenReason != nil { Button("Reconnect") { Task { await connect() } } }
                } else {
                    Button("Connect Google...") { Task { await connect() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!l.available || !l.googleConfigured || waiting)
                }
            }
            if !l.available {
                Text("This server has no database for connectors.").font(.caption).foregroundStyle(.secondary)
            } else if !l.googleConfigured {
                Text("Google is not set up on this server yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func load() async {
        guard model.canReachCloud, model.api.token != nil else { error = "Sign in and connect to manage connectors."; return }
        loading = true
        defer { loading = false }
        do { list = try await model.api.listConnectors(); error = nil }
        catch let e as TRPC.RemoteError where e.isNotFound { error = "This server has no connectors yet." }
        catch { self.error = error.localizedDescription }
    }

    /// Opens the consent page in the browser and polls for the connection for up to three minutes.
    private func connect() async {
        guard model.user?.email != nil else { note = "Sign in first, so the account is tied to yours."; model.showSignIn = true; return }
        do {
            let url = try await model.api.startGoogle()
            guard LinkPolicy.isSafeExternal(url) else { return }
            NSWorkspace.shared.open(url)
            waiting = true
            defer { waiting = false }
            let before = list?.google?.account
            for _ in 0..<60 {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                if let fresh = try? await model.api.listConnectors() {
                    list = fresh
                    if let g = fresh.google, g.brokenReason == nil, g.account != before || before == nil {
                        note = "Google connected. Ask about your mail or calendar."
                        return
                    }
                }
            }
            note = "Google did not finish. Try again, and complete the consent page in your browser."
        } catch {
            note = "Could not start: \(error.localizedDescription)"
        }
    }

    private func disconnect() async {
        do { try await model.api.disconnect(); await load(); note = "Disconnected. Olo can no longer read that account." }
        catch { note = "Could not disconnect: \(error.localizedDescription)" }
    }
}

import OloKit
import SwiftUI
import UIKit

/// Connected accounts (connectors.*), the same as the Mac: Google first, Gmail and Calendar read
/// only. Connect opens Google's consent page in the browser; the callback lands on helius-olo.io,
/// which sends the browser back to olo://connected, and this screen checks connectors.list until
/// the account appears. Tokens never reach the phone. This is how Olo reads email: when a
/// question is about your mail, the server fetches the messages that match and cites them.
struct ConnectorsView: View {
    @EnvironmentObject var model: AppModel
    @State private var list: ConnectorList?
    @State private var loading = false
    @State private var problem: String?
    @State private var note: String?
    @State private var waiting = false

    var body: some View {
        List {
            Section {
                Text("Accounts Olo may read on your behalf when you ask about them: your mail or your calendar, say. Read only. Nothing is read until a question calls for it, and every reply says what was used.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let problem { Section { Text(problem).foregroundStyle(.secondary) } }
            if let l = list {
                Section("Google") { google(l) }
                if l.google != nil && l.google?.brokenReason == nil {
                    Section("Try asking") {
                        ForEach(ConnectorsView.examples, id: \.self) { q in
                            Button(q) { model.ask(q); note = "Asked. Open the Olo tab for the answer." }
                        }
                    }
                }
            }
            Section {
                if waiting { Label("Waiting for Google to finish in your browser", systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary) }
                if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                Button("Refresh") { Task { await load() } }.disabled(loading)
            } footer: {
                Text("Olo never sends email. A draft it writes opens in Mail for you to read and send yourself.")
            }
        }
        .navigationTitle("Connectors")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: model.connectorReturns) { _, _ in Task { await load() } }
    }

    static let examples = ["Summarise my unread email from the last two days.", "Did anyone email me about an invoice this week?", "What is in my calendar tomorrow?"]

    @ViewBuilder private func google(_ l: ConnectorList) -> some View {
        if let g = l.google {
            VStack(alignment: .leading, spacing: 3) {
                Text(g.account)
                Text(g.scopesLine).font(.caption).foregroundStyle(.secondary)
                if let broken = g.brokenReason { Text("Needs reconnecting: \(broken)").font(.caption).foregroundStyle(.orange) }
            }
            if g.brokenReason != nil { Button("Reconnect") { Task { await connect() } }.disabled(waiting) }
            Button("Disconnect", role: .destructive) { Task { await disconnect() } }
        } else {
            Text("Gmail and Calendar, read only.").font(.subheadline).foregroundStyle(.secondary)
            Button("Connect Google") { Task { await connect() } }
                .disabled(!l.available || !l.googleConfigured || waiting)
            if !l.available {
                Text("This server has no database for connectors.").font(.caption).foregroundStyle(.secondary)
            } else if !l.googleConfigured {
                Text("Google is not set up on this server yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        guard model.api.token != nil else { problem = "Sign in to manage connectors."; return }
        loading = true
        defer { loading = false }
        do {
            list = try await model.api.listConnectors()
            problem = nil
        } catch let e as TRPC.RemoteError where e.isNotFound {
            problem = "This server has no connectors yet."
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Opens the consent page in the browser and checks for the connection for up to three minutes.
    private func connect() async {
        guard model.signedIn else { note = "Sign in first, so the account is tied to yours."; model.showSignIn = true; return }
        do {
            let url = try await model.api.startGoogle()
            guard LinkPolicy.isSafeExternal(url) else { return }
            _ = await UIApplication.shared.open(url)
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
        do {
            try await model.api.disconnect()
            await load()
            note = "Disconnected. Olo can no longer read that account."
        } catch {
            note = "Could not disconnect: \(error.localizedDescription)"
        }
    }
}

import SwiftUI
import OloKit

/// Sign in with the same email as on helius-olo.io and the iPhone app: a six digit code, no password.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var sent = false
    @State private var busy = false
    @State private var error: String?
    @State private var consent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to Olo").font(.title2.weight(.semibold))
            Text("Use the email you use on helius-olo.io or the iPhone app; your conversations follow you. What you asked on this Mac moves into the account.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Email", text: $email).disabled(sent)
            if sent {
                TextField("Six digit code", text: $code)
                    .textContentType(.oneTimeCode)
                    .onChange(of: code) { code = String(code.filter(\.isNumber).prefix(6)) }
            }
            if sent {
                Toggle(ConsentText.label, isOn: $consent)
                Text(ConsentText.paragraph).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if sent {
                    Button("Use a different email") { sent = false; code = "" }.buttonStyle(.borderless)
                    Button("Sign In") { Task { await verify() } }.keyboardShortcut(.defaultAction).disabled(code.count != 6 || busy)
                } else {
                    Button("Send Code") { Task { await send() } }.keyboardShortcut(.defaultAction).disabled(!email.contains("@") || busy)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 420)
    }

    private func send() async {
        busy = true; error = nil
        defer { busy = false }
        do { try await model.requestCode(email: email.trimmingCharacters(in: .whitespaces)); sent = true }
        catch { self.error = error.localizedDescription }
    }

    private func verify() async {
        busy = true; error = nil
        defer { busy = false }
        do { try await model.verify(email: email.trimmingCharacters(in: .whitespaces), code: code, trainingConsent: consent); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            FolderSettings().tabItem { Label("Folders", systemImage: "folder") }
            OfflineSettings().tabItem { Label("Offline", systemImage: "wifi.slash") }
            AccountSettings().tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 560)
        .padding(20)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.hotKeyEnabled) private var hotKey = true
    @AppStorage(Prefs.searchWebByDefault) private var searchWeb = false
    @AppStorage(Prefs.useFoldersByDefault) private var useFolders = false
    @AppStorage(Prefs.showUnverified) private var showUnverified = false
    @State private var login = false

    var body: some View {
        Form {
            Toggle("Option+Space opens Quick Ask from any app", isOn: $hotKey)
                .onChange(of: hotKey) {
                    if hotKey { HotKeyCenter.shared.registerQuickAsk() } else { HotKeyCenter.shared.unregister() }
                }
            if let s = HotKeyCenter.shared.registeredShortcut, hotKey, s != "\u{2325}Space" {
                Text("Another app holds Option+Space, so Quick Ask uses \(s).").font(.caption).foregroundStyle(.secondary)
            }
            Text("Select text in any app, then choose Olo > Services > Ask Olo (or right click > Services). You can give it a shortcut in System Settings > Keyboard > Keyboard Shortcuts > Services.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Open Olo at login (in the menu bar)", isOn: $login)
                .onChange(of: login) { model.launchAtLogin = login }
            Toggle("Always show unverified sentences in answers", isOn: $showUnverified)
            Text("Off: only sentences Zeus could support are shown; the rest wait behind a button, labelled.").font(.caption).foregroundStyle(.secondary)
            Toggle("Search the web for new questions", isOn: $searchWeb)
            Toggle("Use my folders for new questions", isOn: $useFolders)
            Section("Where Olo runs") {
                Text("Every answer is written and checked in the cloud: Olo's API (Anthropic, OpenAI and open models on Cloudflare, with Zeus checking each sentence) and Olo Commons. No model runs on this Mac, so Olo stays light; offline, it only searches what is saved here.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { login = model.launchAtLogin }
    }
}

struct FolderSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lib = model.folders
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose folders Olo may search. They are read only when indexed, stay on this Mac, and a passage is sent only with a question you ask with \"Use my folders\" on.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(lib.folders) { f in
                    HStack {
                        Image(systemName: "folder")
                        Text(f.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { lib.remove(f) }.buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 140)
            HStack {
                Button("Add Folder...") { lib.chooseFolder() }
                Button("Index Again") { Task { await lib.reindex() } }.disabled(lib.folders.isEmpty || lib.indexing)
                Spacer()
                if lib.indexing { ProgressView().controlSize(.small); Text("Indexing...") }
                else if lib.lastIndexed != nil { Text("\(lib.fileCount) files, \(lib.chunkCount) passages").foregroundStyle(.secondary) }
            }
            .font(.callout)
        }
    }
}

struct OfflineSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.askPendingWhenOnline) private var askPending = true
    @AppStorage(Prefs.offlineOnly) private var offlineOnly = false

    var body: some View {
        let commons = model.commons
        Form {
            Section("Olo Commons on this Mac") {
                if commons.atomCount > 0 {
                    Text("\(commons.atomCount.formatted()) facts with their sources and licences, built \(commons.builtAt ?? "recently").")
                } else {
                    Text("Not downloaded yet. It downloads by itself the first time Olo is online (about 1 MB).")
                }
                HStack {
                    Button("Update Now") { Task { await commons.refreshIfStale(force: true) } }.disabled(commons.updating || !model.isOnline)
                    if commons.updating { ProgressView().controlSize(.small) }
                    if let e = commons.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                }
            }
            Section("Without a connection") {
                Text("Olo answers by quoting the Commons, your folders and attached files, labelled as unchecked. Your saved conversations stay readable.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Ask offline questions properly when the connection returns", isOn: $askPending)
                Toggle("Offline only: never send anything from this Mac", isOn: $offlineOnly)
                if !model.pending.isEmpty {
                    Text("\(model.pending.count) question\(model.pending.count == 1 ? "" : "s") waiting.").font(.caption)
                }
            }
        }
    }
}

struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmErase = false

    var body: some View {
        Form {
            if let email = model.user?.email {
                LabeledContent("Signed in as", value: email)
                Button("Sign Out") { model.signOut() }
            } else {
                Text(model.user == nil ? "Not signed in. Olo gives you free messages to start; sign in to use your account." : "Using free messages on this Mac.")
                Button("Sign In...") { model.showSignIn = true; model.showMainWindow() }
            }
            Section("Training") {
                Toggle(ConsentText.label, isOn: Binding(get: { model.trainingConsent }, set: { model.trainingConsent = $0 }))
                Text(ConsentText.paragraph).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Data on this Mac") {
                Text("Copies of your conversations, questions waiting for a connection and the Commons copy are kept in Olo's own container. Your account data lives on helius-olo.io.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Remove Local Data...", role: .destructive) { confirmErase = true }
                    .confirmationDialog("Remove everything Olo saved on this Mac?", isPresented: $confirmErase) {
                        Button("Remove", role: .destructive) { model.eraseLocalData() }
                    } message: { Text("Your account and conversations on helius-olo.io are not affected.") }
                Link("Privacy policy", destination: URL(string: "https://helius-olo.io/privacy")!)
            }
        }
    }
}


/// The one consent that matters, in the same words on every Olo app.
enum ConsentText {
    static let label = "Use my conversations to improve Olo and train Zeus"
    static let paragraph = "Olo is a paid product. With this on, your questions and answers may be used to improve Olo and to train Zeus, Olo's open-source verifier. Flags you send from a verdict are always used, because sending one is your choice. Memory and attached files are never used for training. Conversations can be deleted, and links to them are never indexed by search engines."
}

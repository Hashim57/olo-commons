import SwiftUI
import UniformTypeIdentifiers
import OloKit

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            if let panel = model.panel {
                PanelHost(panel: panel).id(panel)
            } else if let id = model.selection, model.conversation(id) != nil {
                ChatView(conversationId: id).id(id)
            } else {
                EmptyState()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.newConversation() } label: { Label("New Conversation", systemImage: "square.and.pencil") }
                    .help("New conversation (Cmd+N)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.panel = .build } label: { Label("Build with Olo", systemImage: "hammer") }
                    .help("Build with Olo: Olo reviews your project's files as you save them, in any editor")
            }
            ToolbarItem(placement: .status) {
                if !model.isOnline {
                    Label("Offline", systemImage: "wifi.slash").foregroundStyle(.orange)
                        .help("Answers come from what is saved on this Mac until the connection returns.")
                }
            }
        }
        .sheet(isPresented: $model.showSignIn) { SignInView() }
        .sheet(isPresented: $model.showSubscribe) { SubscribeView(store: model.purchases) }
        .sheet(isPresented: $model.showTerms) { TermsGateView() }
        .sheet(isPresented: $model.showBrainChoice) { BrainChoiceSheet() }
        .onChange(of: model.showTerms) { if !model.showTerms { model.considerBrainChoice() } }
        .overlay(alignment: .top) {
            if let b = model.banner {
                Text(b).font(.callout).padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
                    .onTapGesture { model.banner = nil }
                    .task { try? await Task.sleep(nanoseconds: 6_000_000_000); model.banner = nil }
            }
        }
    }
}

struct AccountFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let email = model.user?.email {
                    Label(email, systemImage: "person.crop.circle").lineLimit(1).font(.callout)
                } else {
                    Button { model.showSignIn = true } label: { Label("Sign In", systemImage: "person.crop.circle.badge.plus") }
                        .help("Use the same account as helius-olo.io and the iPhone app")
                }
                Spacer()
            }
            UsageMeter(compact: true)
        }
        .buttonStyle(.borderless)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // An opaque bar with a rule above it, so conversations scroll under it instead of showing through.
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// The empty state: the atom, the question, and the four things people try first (the web's FirstRun).
struct EmptyState: View {
    @Environment(AppModel.self) private var model
    @State private var question = ""

    private static let starters: [(label: String, prompt: String, note: String)] = [
        ("Build something", "Build me a one-page site explaining what my business does, with a contact form", "Produces a file you can preview and save"),
        ("Check it against sources", "What does current research say about sargassum as a biofuel feedstock?", "Turn on Search the web and every claim is checked against what it found"),
        ("Work through a decision", "Compare hiring a contractor against training someone in-house for a six month project", "Olo weighs the competing factors"),
        ("Keep context in one place", "I want to set up a project for my planning work", "Projects hold standing instructions and reference files"),
    ]

    var body: some View {
        VStack(spacing: 18) {
            HeliusAtomView(mode: .idle, size: 180)
            HeliusAtomCaption()
            Text("Ask Olo").font(.largeTitle.weight(.semibold))
            Text("Answers from sources you can open, with every sentence checked.\nPress Option+Space in any app to ask without leaving it.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            TextField("Ask anything", text: $question)
                .textFieldStyle(.roundedBorder).font(.title3).frame(maxWidth: 520)
                .onSubmit { let q = question; question = ""; model.ask(q, in: model.newConversation()) }
            starterRow
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var starterRow: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<EmptyState.starters.count, id: \.self) { i in
                let s = EmptyState.starters[i]
                Button {
                    model.ask(s.prompt, in: model.newConversation(), searchWeb: i == 1)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.label).font(.callout.weight(.medium))
                        Text(s.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: 760)
    }
}

import SwiftUI
import UniformTypeIdentifiers
import OloKit

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let id = model.selection, model.conversation(id) != nil {
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
            ToolbarItem(placement: .status) {
                if !model.isOnline {
                    Label("Offline", systemImage: "wifi.slash").foregroundStyle(.orange)
                        .help("Answers come from what is saved on this Mac until the connection returns.")
                }
            }
        }
        .sheet(isPresented: $model.showSignIn) { SignInView() }
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

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    private var filtered: [LocalConversation] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty ? model.conversations : model.conversations.filter { $0.title.lowercased().contains(f) }
    }

    var body: some View {
        let selection = Binding<UUID?>(get: { model.selection }, set: { if let id = $0 { model.open(id) } else { model.selection = nil } })
        List(selection: selection) {
            let pinned = filtered.filter(\.isPinned)
            if !pinned.isEmpty {
                Section("Pinned") { ForEach(pinned) { row($0) } }
            }
            Section(model.user?.email ?? "Conversations") {
                ForEach(filtered.filter { !$0.isPinned }) { row($0) }
            }
        }
        .searchable(text: $filter, placement: .sidebar, prompt: "Search conversations")
        .safeAreaInset(edge: .bottom) { AccountFooter() }
        .refreshable { await model.refreshConversations() }
    }

    private func row(_ c: LocalConversation) -> some View {
        HStack(spacing: 6) {
            if c.serverId == nil { Image(systemName: "desktopcomputer").foregroundStyle(.secondary).help("Only on this Mac so far") }
            Text(c.title).lineLimit(1)
            Spacer(minLength: 0)
            if model.answering[c.id] != nil { ProgressView().controlSize(.mini) }
        }
        .tag(c.id)
        .contextMenu {
            Button("Delete from This Mac", role: .destructive) { model.delete(c.id) }
        }
    }
}

struct AccountFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            if let email = model.user?.email {
                Label(email, systemImage: "person.crop.circle").lineLimit(1).font(.callout)
            } else {
                Button { model.showSignIn = true } label: { Label("Sign In", systemImage: "person.crop.circle.badge.plus") }
                    .help("Use the same account as helius-olo.io and the iPhone app")
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(10)
    }
}

struct EmptyState: View {
    @Environment(AppModel.self) private var model
    @State private var question = ""

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "text.bubble").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Ask Olo").font(.largeTitle.weight(.semibold))
            Text("Answers from sources you can open, with every sentence checked.\nPress Option+Space in any app to ask without leaving it.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            TextField("Ask anything", text: $question)
                .textFieldStyle(.roundedBorder).font(.title3).frame(maxWidth: 520)
                .onSubmit { let q = question; question = ""; model.ask(q, in: model.newConversation()) }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

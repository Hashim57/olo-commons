import SwiftUI
import OloKit

/// Olo for macOS: a native app on the same account as helius-olo.io and the iPhone
/// app. Answers are written and checked in the cloud (Olo's API with Anthropic,
/// OpenAI and open models on Cloudflare, with Zeus checking every sentence); no
/// model ever runs on this Mac. Offline, Olo answers by quoting the copy of Olo
/// Commons and your own files saved here, and asks properly once you are back.
@main
struct OloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Olo", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1100, height: 760)
        .commands { OloCommands(model: model) }

        MenuBarExtra {
            MenuBarMenu().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

struct OloCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Subscribe...") { model.openSubscribe() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") { model.newConversation(); model.showMainWindow() }
                .keyboardShortcut("n")
            // Option+Space works from every app (see HotKey.swift), so it is not repeated here.
            Button("New Private Chat") { model.newPrivateConversation(); model.showMainWindow() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Build with Olo") { model.panel = .build; model.showMainWindow() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Ask Olo (Quick Ask)") { QuickAskController.shared.toggle() }
            Divider()
            Button("Attach Files...") { model.requestAttachFiles = true }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .sidebar) {
            Button("Refresh Conversations") { Task { await model.refreshConversations() } }
                .keyboardShortcut("r")
        }
        CommandGroup(replacing: .help) {
            Link("Olo Support", destination: URL(string: "https://helius-olo.io/support")!)
            Link("Olo Commons", destination: URL(string: "https://heliusnetwork.app/olo")!)
            Link(BrainText.viewBrain, destination: BrainLinks.view)
            Link("Privacy", destination: URL(string: "https://helius-olo.io/privacy")!)
        }
    }
}

/// The menu bar item. It is always on screen, which makes it the place to hand the
/// app's "open the main window" action to code outside SwiftUI (Quick Ask, Services).
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.isOnline ? "text.bubble" : "text.bubble.fill")
            .task { model.openMainWindowAction = { openWindow(id: "main") } }
            .accessibilityLabel("Olo")
    }
}

struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Ask Olo...  \u{2325}Space") { QuickAskController.shared.show() }
        Button("New Conversation") { model.newConversation(); NSApp.activate(ignoringOtherApps: true); openWindow(id: "main") }
        Button("Open Olo") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "main") }
        Divider()
        Text(model.isOnline ? "Online: answers are written and checked in the cloud" : "Offline: answering from what is saved on this Mac")
        if !model.pending.isEmpty {
            Text("\(model.pending.count) question\(model.pending.count == 1 ? "" : "s") waiting for a connection")
        }
        Divider()
        SettingsLink { Text("Settings...") }
        Button("Quit Olo") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

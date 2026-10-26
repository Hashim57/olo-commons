import AppKit
import SwiftUI
import OloKit

/// The floating Quick Ask panel (Option+Space from any app, or Services > Ask Olo).
/// It floats above every app and every Space without taking you out of what you
/// were doing; Esc closes it.
@MainActor
final class QuickAskController {
    static let shared = QuickAskController()
    private var panel: QuickAskPanel?
    let state = QuickAskState()

    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow { panel.orderOut(nil) } else { show() }
    }

    func show(question: String? = nil, attachments: [Attachment] = [], notice: String? = nil) {
        if let question { state.question = question }
        if !attachments.isEmpty { state.attachments = attachments; state.conversation = nil }
        state.notice = notice
        let p = panel ?? makePanel()
        panel = p
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            let size = p.frame.size
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - f.height * 0.18))
        }
        p.makeKeyAndOrderFront(nil)
        state.focusToken += 1
    }

    func close() { panel?.orderOut(nil) }

    private func makePanel() -> QuickAskPanel {
        let p = QuickAskPanel()
        p.contentView = NSHostingView(rootView: QuickAskView(state: state).environment(AppModel.shared))
        return p
    }
}

@MainActor @Observable
final class QuickAskState {
    var question = ""
    var attachments: [Attachment] = []
    var conversation: UUID?
    var notice: String?
    var focusToken = 0
}

final class QuickAskPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        minSize = NSSize(width: 460, height: 160)
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

struct QuickAskView: View {
    @Bindable var state: QuickAskState
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    private var conversation: LocalConversation? { model.conversation(state.conversation) }
    private var isAnswering: Bool { state.conversation.flatMap { model.answering[$0] } != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble").font(.title2).foregroundStyle(.tint)
                TextField("Ask Olo anything", text: $state.question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                if isAnswering, let c = state.conversation {
                    Button { model.stop(c) } label: { Image(systemName: "stop.circle.fill") }.buttonStyle(.plain).help("Stop")
                }
            }
            if !state.attachments.isEmpty {
                AttachmentChips(attachments: $state.attachments)
            }
            if let n = state.notice { Text(n).font(.callout).foregroundStyle(.secondary) }
            if let c = conversation, let last = c.turns.last(where: { $0.role == .assistant }) {
                Divider()
                ScrollView {
                    TurnView(turn: last, status: model.answering[c.id], compact: true) { follow in state.question = follow; send() }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
                HStack {
                    Button("Open in Olo") {
                        model.open(c.id)
                        model.showMainWindow()
                        QuickAskController.shared.close()
                    }
                    Button("New Question") { state.conversation = nil; state.question = ""; state.attachments = []; focused = true }
                    Spacer()
                    Text(model.isOnline ? "Written and checked in the cloud" : "Offline").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Button {
                        if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
                            state.attachments.append(Attachment(kind: .selection, name: "Clipboard", text: s))
                        }
                    } label: { Label("Use Clipboard", systemImage: "doc.on.clipboard") }
                    Spacer()
                    Text("Return to ask, Esc to close").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 26)
        .padding(.bottom, 14)
        .frame(minWidth: 460, maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .onChange(of: state.focusToken) { focused = true }
        .onAppear { focused = true }
    }

    private func send() {
        let q = state.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty || !state.attachments.isEmpty, !isAnswering else { return }
        let cid: UUID
        if let existing = state.conversation, model.conversation(existing) != nil {
            cid = existing
        } else {
            let c = LocalConversation(title: LocalConversation.title(for: q.isEmpty ? "Selected text" : q))
            model.conversations.insert(c, at: 0)
            cid = c.id
            state.conversation = cid
        }
        model.ask(q, attachments: state.attachments, in: cid,
                  searchWeb: UserDefaults.standard.bool(forKey: Prefs.searchWebByDefault),
                  useFolders: UserDefaults.standard.bool(forKey: Prefs.useFoldersByDefault))
        state.question = ""
        state.attachments = []
    }
}

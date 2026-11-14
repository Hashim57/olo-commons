import SwiftUI
import OloKit

/// Edit in place (chat.editPassage), as the web's EditablePassage and the iPhone's
/// EditPassageSheet do: pick the passage, say what should change, and only that passage is
/// rewritten; the rest of the answer stays word for word. On a Mac the passage is chosen by
/// clicking a sentence (or typing it), since SwiftUI text selection is not readable here.
struct EditPassageSheet: View {
    let conversationId: UUID
    let turn: Turn
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var passage = ""
    @State private var instruction = ""
    @State private var busy = false
    @State private var error: String?

    private var sentences: [String] { Abstain.sentences(of: ChartBlocks.textOnly(turn.text)) }

    private var input: EditPassageInput? {
        guard let c = model.conversation(conversationId), let sid = c.serverId, let mid = turn.serverMessageId else { return nil }
        return EditPassageInput(conversationId: sid, messageId: mid, passage: passage, instruction: instruction)
    }

    private var problem: String? {
        guard let input else { return "This answer is not saved on helius-olo.io yet, so it cannot be edited there." }
        return input.problem
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit a passage").font(.title2.weight(.semibold))
            Text("Click the sentence to change, or type the passage. Everything else stays as it is. The verdicts are not re-checked by the edit; use Fix flagged sentences afterwards if you want them re-run.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(sentences.enumerated()), id: \.offset) { _, s in
                        Button { passage = s } label: {
                            Text(s).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .background(passage == s ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            .frame(minHeight: 140, maxHeight: 260)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            TextField("The passage to rewrite", text: $passage, axis: .vertical).lineLimit(1...4)
            TextField("What should change?", text: $instruction, axis: .vertical).lineLimit(1...3)
                .onSubmit { Task { await submit() } }
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small); Text("Rewriting").font(.caption).foregroundStyle(.secondary) }
                Button("Rewrite") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || problem != nil)
                    .help(problem ?? "Only this passage is rewritten")
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 560)
    }

    private func submit() async {
        guard let input, input.problem == nil, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result = try await model.api.editPassage(input)
            await model.applyEdit(result, cid: conversationId, tid: turn.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

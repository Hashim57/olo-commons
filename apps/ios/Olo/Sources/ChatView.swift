import OloKit
import SwiftUI

/// The conversation: the same Olo as the Mac and the web. One reading column, the answer checked
/// sentence by sentence, the switches under the composer.
struct ChatView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var voice: Voice
    @State private var draft = ""
    @State private var showHistory = false
    @FocusState private var focused: Bool

    private let starters = ["Build something", "Check it against sources", "Work through a decision"]
    private let starterPrompts = ["Help me build a simple budget for this month.", "Is it true that the Great Wall of China is visible from space? Check it against sources.", "Help me think through whether to take a new job offer."]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let banner = model.banner {
                    Text(banner).font(.footnote).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.18))
                        .onTapGesture { model.banner = nil }
                }
                if model.items.isEmpty { empty } else { thread }
                composer
            }
            .navigationTitle(model.isPrivate ? "Private chat" : "Olo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: { Image(systemName: "sidebar.left") }.accessibilityLabel("Conversations")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.newConversation() } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New conversation")
                }
            }
            .sheet(isPresented: $showHistory) { HistoryView() }
        }
    }

    private var empty: some View {
        ScrollView {
            VStack(spacing: 14) {
                OloFace(mood: model.mood, size: 150).padding(.top, 30)
                Text("Ask Olo").font(.largeTitle.bold())
                Text("Answers from sources you can open, with every sentence checked. Olo says so when something cannot be verified.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 28)
                VStack(spacing: 8) {
                    ForEach(0..<starters.count, id: \.self) { i in
                        Button { model.ask(starterPrompts[i]) } label: {
                            Text(starters[i]).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.items) { item in
                        MessageView(item: item).id(item.id)
                    }
                    Text("Olo is AI and can make mistakes. Check anything that matters against its sources.")
                        .font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 6)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.items.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.items.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if voice.listening {
                Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript).font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
            }
            if let problem = voice.problem { Text(problem).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Olo", text: $draft, axis: .vertical).lineLimit(1...5).focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Button {
                    if voice.listening { let heard = voice.finish(); if !heard.isEmpty { model.ask(heard) } }
                    else { focused = false; Task { await voice.start() } }
                } label: {
                    Image(systemName: voice.listening ? "waveform.circle.fill" : "mic.circle").font(.system(size: 32))
                }
                .accessibilityLabel(voice.listening ? "Stop listening and ask" : "Talk to Olo")
                Button {
                    if model.sending { model.stop() } else { let q = draft; draft = ""; model.ask(q) }
                } label: {
                    Image(systemName: model.sending ? "stop.circle.fill" : "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(!model.sending && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(model.sending ? "Stop" : "Send")
            }
            Picker("Depth", selection: $model.tier) {
                Text("Swift").tag("low"); Text("Standard").tag("medium"); Text("Deep").tag("high")
            }
            .pickerStyle(.segmented)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(title: "Sources", icon: "magnifyingglass", on: $model.grounded)
                    Chip(title: "Olo brain", icon: "sparkles", on: $model.brain).disabled(model.isPrivate)
                    Chip(title: "Private", icon: "lock", on: $model.isPrivate)
                    Chip(title: "Challenge me", icon: "figure.fencing", on: $model.challenge)
                    Chip(title: "Read aloud", icon: "speaker.wave.2", on: $model.speakAnswers)
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
        .background(.bar)
    }
}

struct Chip: View {
    let title: String
    let icon: String
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            Label(title, systemImage: icon).font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(on ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct MessageView: View {
    @EnvironmentObject var model: AppModel
    let item: ChatItem
    @State private var showClaims = false

    private func rich(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    var body: some View {
        if item.role == "user" {
            Text(item.text).padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if !item.text.isEmpty { Text(rich(item.text)).textSelection(.enabled) }
                if let status = item.status, item.streaming {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(status).font(.footnote).foregroundStyle(.secondary) }
                }
                ForEach(item.notices, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                if let v = item.verification, !item.streaming { verdicts(v) }
                if !item.sources.isEmpty && !item.streaming { sources }
                if !item.followUps.isEmpty && !item.streaming {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(item.followUps, id: \.self) { q in
                            Button { model.ask(q) } label: {
                                Text(q).font(.footnote).multilineTextAlignment(.leading).padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func verdicts(_ v: AnswerVerification) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { showClaims.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("Zeus").font(.footnote.bold())
                    Text("\(v.supported) supported · \(v.flaggedCount) unverified").font(.footnote).foregroundStyle(.secondary)
                    Image(systemName: showClaims ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if showClaims {
                ForEach(Array(v.claims.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .top, spacing: 8) {
                        Text(c.verdict == "supported" ? "SUPPORTED" : c.verdict == "contradicted" ? "CONTRADICTED" : "UNVERIFIED")
                            .font(.system(size: 9, weight: .heavy)).padding(.horizontal, 7).padding(.vertical, 4)
                            .background(c.verdict == "supported" ? Color.green : c.verdict == "contradicted" ? Color.red : Color(.systemGray3), in: Capsule())
                            .foregroundStyle(c.verdict == "unsupported" ? Color.primary : Color.white)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.claim).font(.footnote)
                            if !c.rationale.isEmpty { Text(c.rationale).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Text("Answered by Olo, checked by Zeus").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sources: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(item.sources, id: \.self) { s in
                    if let url = URL(string: s.url) {
                        Link(destination: url) {
                            Text("\(s.index)  \(s.title)").font(.caption).lineLimit(1).frame(maxWidth: 200)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .overlay(Capsule().stroke(Color(.separator)))
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if model.conversations.isEmpty {
                    Text("Your conversations will appear here.").foregroundStyle(.secondary)
                }
                ForEach(model.conversations) { c in
                    Button {
                        Task { await model.open(c); dismiss() }
                    } label: {
                        Text(c.title).lineLimit(2).foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await model.loadConversations() }
        }
    }
}

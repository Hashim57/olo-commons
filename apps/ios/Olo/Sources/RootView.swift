import OloKit
import SwiftUI

enum AppTab: Hashable { case olo, today, library, settings }

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var calendar: CalendarBridge
    @EnvironmentObject var voice: Voice
    @EnvironmentObject var companion: Companion
    @ObservedObject private var pending = PendingAsk.shared
    @Environment(\.scenePhase) private var phase
    @State private var tab: AppTab = .olo

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                ChatView().tabItem { Label("Olo", systemImage: "bubble.left.and.text.bubble.right") }.tag(AppTab.olo)
                TodayView(tab: $tab).tabItem { Label("Today", systemImage: "calendar") }.tag(AppTab.today)
                LibraryView().tabItem { Label("Library", systemImage: "books.vertical") }.tag(AppTab.library)
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
            }
            FloatingOlo(tab: $tab)
        }
        .sheet(isPresented: $model.showSignIn) { SignInView() }
        .sheet(isPresented: $model.showPlans) { PlansView(store: model.purchases) }
        .onOpenURL { url in
            if case .some(.ask) = LinkPolicy.parse(url) { tab = .olo }
            model.handle(url: url)
        }
        .fullScreenCover(isPresented: .constant(model.needsTerms)) { TermsGate() }
        .task {
            model.onAnswer = { text in if model.speakAnswers { voice.speak(text) } }
            await model.refreshProfile()
            await model.loadConversations()
            await model.bootstrapBilling()
            await calendar.reload()
            refreshCompanion()
        }
        .onChange(of: pending.question) { _, question in
            guard let question, !question.isEmpty else { return }
            pending.question = nil
            tab = .olo
            model.ask(question)
        }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await calendar.reload(); refreshCompanion() } }
        }
        .onChange(of: model.mood) { _, _ in refreshCompanion() }
    }

    /// Keeps the Lock Screen, the Dynamic Island and the widget in step with the app.
    private func refreshCompanion() {
        let next = DayPlan.next(calendar.upcoming, after: Date())
        let line: String
        switch model.mood {
        case .thinking: line = "Olo is working on your question."
        case .happy: line = "Your answer is ready."
        case .unsure: line = "Your answer is ready. Some of it could not be verified."
        case .idle: line = next == nil ? "Nothing else in your calendar today." : "Next in your day"
        }
        companion.show(mood: model.mood, line: line, next: next)
    }
}

/// The small Olo that floats over every screen of the app. Drag it anywhere; tap it for a
/// suggestion that fits the screen you are on.
struct FloatingOlo: View {
    @EnvironmentObject var model: AppModel
    @Binding var tab: AppTab
    @State private var offset = CGSize(width: 0, height: 0)
    @State private var drag = CGSize.zero
    @State private var open = false
    @State private var turn = 0

    private var prompts: [(String, String)] {
        switch tab {
        case .olo: return [("Ask me anything. I will show you what I could verify.", "What should I check before signing a tenancy agreement?"),
                           ("Try a question with a date in it. I check those hardest.", "When was the Internet Archive founded, and by whom?")]
        case .today: return [("I can plan the day around what is in your calendar.", "Help me plan today around my calendar."),
                             ("Short of time? Ask me what can wait.", "Looking at a busy day, how do I decide what can wait?")]
        case .library: return [("Everything I remember is here, and you approve each one.", "What do you remember about me?"),
                               ("Connect Google under Mail and calendar and I can read your mail when you ask.", "Summarise my unread email from the last two days."),
                               ("Open Build with Olo and tell me what to make.", "What can you build for me on this phone?")]
        case .settings: return [("Your private chats are never stored. Ask me how that works.", "How do private chats work in Olo?")]
        }
    }

    var body: some View {
        GeometryReader { geo in
            let item = prompts[turn % prompts.count]
            VStack(alignment: .trailing, spacing: 8) {
                if open {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.0).font(.footnote.weight(.medium)).foregroundStyle(.white)
                        Button {
                            open = false; tab = .olo; model.ask(item.1)
                        } label: {
                            Text(item.1).font(.caption.weight(.semibold)).multilineTextAlignment(.leading)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.black)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 250, alignment: .leading)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 16))
                    .transition(.opacity)
                }
                OloFace(mood: model.mood, size: 64, animated: true,
                        look: CGSize(width: max(-1, min(1, drag.width / 60)), height: max(-1, min(1, drag.height / 60))))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { if !open { turn += 1 }; open.toggle() } }
                    .gesture(DragGesture(minimumDistance: 6)
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            var next = CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height)
                            next.width = max(-(geo.size.width - 100), min(0, next.width))
                            next.height = max(-(geo.size.height - 260), min(30, next.height))
                            withAnimation(.easeOut(duration: 0.25)) { offset = next; drag = .zero }
                        })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 14)
            .padding(.bottom, 96)
            .offset(x: offset.width + drag.width, y: offset.height + drag.height)
        }
        .ignoresSafeArea(.keyboard)
    }
}

/// Shown before the first conversation, and again when the terms change.
struct TermsGate: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    OloFace(mood: .happy, size: 96).frame(maxWidth: .infinity)
                    Text("Before you start").font(.largeTitle.bold())
                    ForEach(Array(Legal.summary.enumerated()), id: \.offset) { _, point in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(point.title).font(.headline)
                            Text(point.text).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 16) {
                        Link("Terms of Use", destination: Legal.termsURL)
                        Link("Privacy Policy", destination: Legal.privacyURL)
                    }
                    .font(.subheadline)
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.termsAccepted = Legal.termsVersion
                } label: {
                    Text("I agree").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(20)
                .background(.bar)
            }
        }
        .interactiveDismissDisabled()
    }
}

/// Sign in with a code sent by email, as on the web and the Mac.
struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var sent = false
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if sent {
                        TextField("Code from the email", text: $code)
                            .textContentType(.oneTimeCode).keyboardType(.numberPad)
                    }
                } footer: {
                    Text(sent ? "Enter the code we sent. It works once and expires soon." : "We send a code to this address. The same account works on the web, the Mac and the iPhone.")
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
                Section {
                    Button(sent ? "Sign in" : "Send me a code") {
                        Task {
                            busy = true; problem = nil
                            if sent { problem = await model.verify(email: email, code: code) }
                            else { problem = await model.requestCode(email); if problem == nil { sent = true } }
                            busy = false
                        }
                    }
                    .disabled(busy || email.isEmpty || (sent && code.isEmpty))
                }
            }
            .navigationTitle("Sign in to Olo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

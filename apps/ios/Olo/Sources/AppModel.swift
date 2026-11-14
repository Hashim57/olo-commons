import Foundation
import OloKit
import SwiftUI

/// One bubble in the conversation.
struct ChatItem: Identifiable, Equatable {
    let id = UUID()
    var role: String            // "user" or "assistant"
    var text: String
    var status: String?
    var verification: AnswerVerification?
    var sources: [Source] = []
    var followUps: [String] = []
    var notices: [String] = []
    /// Files the answer produced, and the names of the files that went with the question.
    var artifacts: [Artifact] = []
    var attached: [String] = []
    /// A build that outran the live answer and carries on in the background.
    var buildJobId: String?
    var streaming = false
    var failed = false
}

/// The iPhone app's state: the session, the conversation on screen and the switches under the
/// composer. Everything that talks to helius-olo.io goes through OloKit, as on the Mac.
@MainActor
final class AppModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var conversations: [Conversation] = []
    @Published var conversationId: Int?
    @Published var sending = false
    @Published var mood: OloMood = .idle
    /// The signed-in email, or nil for an anonymous workspace.
    @Published var email: String?
    @Published var banner: String?
    @Published var showSignIn = false
    /// What the account may do now (the plan and what is left of it), once the server has said.
    @Published var entitlement: Entitlement?
    @Published var showPlans = false
    /// Files waiting to go with the next question.
    @Published var attachments: [Attachment] = []
    /// The project questions are asked in, if any: its instructions and files go with each one.
    @Published var activeProject: Project?
    /// Counts up when the browser returns from a connector's consent page (olo://connected).
    @Published var connectorReturns = 0

    // The switches under the composer, as on the Mac and the web.
    @Published var tier: String = UserDefaults.standard.string(forKey: "olo.tier") ?? "medium" { didSet { UserDefaults.standard.set(tier, forKey: "olo.tier") } }
    @Published var grounded: Bool = UserDefaults.standard.bool(forKey: "olo.sources") { didSet { UserDefaults.standard.set(grounded, forKey: "olo.sources") } }
    @Published var brain: Bool = UserDefaults.standard.bool(forKey: "olo.brain") { didSet { UserDefaults.standard.set(brain, forKey: "olo.brain") } }
    @Published var challenge: Bool = UserDefaults.standard.bool(forKey: "olo.challenge") { didSet { UserDefaults.standard.set(challenge, forKey: "olo.challenge") } }
    @Published var isPrivate = false
    @Published var speakAnswers: Bool = UserDefaults.standard.bool(forKey: "olo.speak") { didSet { UserDefaults.standard.set(speakAnswers, forKey: "olo.speak") } }
    @Published var termsAccepted: String = UserDefaults.standard.string(forKey: "olo.termsAccepted") ?? "" { didSet { UserDefaults.standard.set(termsAccepted, forKey: "olo.termsAccepted") } }

    let api: OloAPI
    let purchases = StoreController()
    private var task: Task<Void, Never>?
    var onAnswer: ((String) -> Void)?

    init() {
        api = OloAPI(token: Keychain.read("session"))
    }

    var needsTerms: Bool { termsAccepted != Legal.termsVersion }
    var signedIn: Bool { email != nil }

    // MARK: Session

    /// A session to ask with: the saved one, or a new anonymous workspace with the free allowance.
    func ensureSession() async throws {
        if api.token != nil { return }
        let s = try await api.createSession()
        api.token = s.token
        Keychain.write("session", s.token)
        email = s.user.email
    }

    func refreshProfile() async {
        guard api.token != nil else { return }
        if let p = try? await api.profile() { email = p.email }
    }

    func requestCode(_ email: String) async -> String? {
        do { try await api.requestEmailCode(email); return nil } catch { return error.localizedDescription }
    }

    func verify(email: String, code: String) async -> String? {
        do {
            let s = try await api.verifyEmailCode(email: email, code: code)
            api.token = s.token
            Keychain.write("session", s.token)
            self.email = s.user.email ?? email
            showSignIn = false
            await loadConversations()
            await refreshEntitlement()
            return nil
        } catch { return error.localizedDescription }
    }

    func signOut() {
        task?.cancel()
        api.token = nil
        Keychain.write("session", nil)
        email = nil; items = []; conversations = []; conversationId = nil
        entitlement = nil; activeProject = nil; attachments = []
    }

    // MARK: Conversations

    func loadConversations() async {
        guard api.token != nil else { return }
        if let list = try? await api.listConversations() { conversations = list }
    }

    func open(_ c: Conversation) async {
        task?.cancel(); sending = false
        conversationId = c.id; isPrivate = false
        guard let messages = try? await api.messages(conversationId: c.id) else { banner = "That conversation could not be loaded."; return }
        items = messages.map { m in
            ChatItem(role: m.role == "user" ? "user" : "assistant", text: m.content, verification: m.verification, sources: m.sources ?? [])
        }
    }

    func newConversation() {
        task?.cancel(); sending = false
        conversationId = nil; items = []; mood = .idle
    }

    // MARK: Asking

    func stop() {
        task?.cancel()
        sending = false; mood = .idle
        if let i = items.indices.last, items[i].streaming { items[i].streaming = false; items[i].status = nil }
    }

    /// Sends a question and streams the answer as it is written and checked.
    func ask(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard !(text.isEmpty && files.isEmpty), !sending else { return }
        banner = nil
        attachments = []
        let composed = MessageComposer.compose(question: text, attachments: files)
        if !composed.trimmed.isEmpty { banner = "Too long to send whole, so the end was left out: " + composed.trimmed.joined(separator: ", ") + "." }
        let project = activeProject?.id
        items.append(ChatItem(role: "user", text: text.isEmpty ? "Explain this." : text, attached: files.map(\.name)))
        items.append(ChatItem(role: "assistant", text: "", status: "Thinking", streaming: true))
        let index = items.count - 1
        sending = true; mood = .thinking
        let privateNow = isPrivate

        task = Task { [weak self] in
            guard let self else { return }
            var outcome = StreamOutcome()
            do {
                try await self.ensureSession()
                var input = OloAPI.AskInput(conversationId: privateNow ? nil : self.conversationId, content: composed.content, grounded: self.grounded,
                                            projectId: project, challenge: self.challenge, brain: self.brain, isPrivate: privateNow)
                input.tier = self.tier
                input.autoTier = self.tier == "medium"
                input.client = "ios"
                for try await event in self.api.ask(input) {
                    if Task.isCancelled { break }
                    outcome.apply(event)
                    guard self.items.indices.contains(index) else { break }
                    self.items[index].text = outcome.text
                    self.items[index].status = outcome.completed ? nil : outcome.status
                    self.items[index].verification = outcome.verification
                    self.items[index].sources = outcome.sources
                    self.items[index].followUps = outcome.followUps
                    self.items[index].notices = outcome.notices
                    self.items[index].artifacts = outcome.artifacts
                    if case .truncated(let jobId, _) = event, let jobId { self.items[index].buildJobId = jobId }
                    if case .error(let message, _, _) = event { self.items[index].failed = true; self.banner = message }
                }
                if !privateNow, let id = outcome.conversationId { self.conversationId = id }
            } catch let failure as OloAPI.StreamFailure {
                if failure.isQuota {
                    self.banner = self.signedIn ? failure.message : "You have used today's free questions. Sign in to carry on."
                    self.showSignIn = !self.signedIn
                    if self.signedIn {
                        await self.refreshEntitlement()
                        if self.entitlement?.isFree ?? true { self.showPlans = true }
                    }
                } else if failure.isUnauthorized {
                    self.api.token = nil; Keychain.write("session", nil); self.email = nil
                    self.banner = "Your session ended. Ask again to start a new one."
                } else {
                    self.banner = failure.message
                }
                if self.items.indices.contains(index) { self.items[index].failed = true }
            } catch is CancellationError {
                // stopped by the person
            } catch {
                self.banner = OloAPI.isTransientNetworkError(error) ? "Olo could not be reached. Check your connection and ask again." : error.localizedDescription
                if self.items.indices.contains(index) { self.items[index].failed = true }
            }
            guard self.items.indices.contains(index) else { return }
            self.items[index].streaming = false
            self.items[index].status = nil
            if self.items[index].text.isEmpty && self.items[index].failed { self.items.remove(at: index) }
            self.sending = false
            let flagged = outcome.verification?.flaggedCount ?? 0
            self.mood = outcome.text.isEmpty ? .idle : (flagged > 0 ? .unsure : .happy)
            if !outcome.text.isEmpty { self.onAnswer?(outcome.text) }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !self.sending { self.mood = .idle }
            if !privateNow { await self.loadConversations() }
        }
    }
}

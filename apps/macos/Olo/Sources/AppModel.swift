import AppKit
import Observation
import ServiceManagement
import SwiftUI
import OloKit

/// The app's state: your account, conversations (the same ones as on the web and
/// iPhone), what is being answered, and whether the Mac is online.
///
/// Where answers come from, in order:
/// 1. helius-olo.io (Olo's API): written by cloud models, every sentence checked by Zeus.
/// 2. Olo Commons' own service, if helius-olo.io cannot be reached but the internet can.
/// 3. Offline: sentences quoted from the Commons copy and your files on this Mac,
///    labelled unchecked, and the question queued to be asked properly later.
/// None of these runs a model on the Mac.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let api: OloAPI
    let store = LocalStore.appSupport()
    private let connectivity = Connectivity()
    let commons: CommonsLibrary
    let folders = FolderLibrary()

    var user: SessionUser?
    var conversations: [LocalConversation] = []
    var selection: UUID?
    var pending: [PendingQuestion] = []
    var isOnline = true
    /// Conversations with an answer on the way, and what Olo is doing for each.
    var answering: [UUID: String] = [:]
    var banner: String?
    var showSignIn = false
    var requestAttachFiles = false
    // Terms and plan (see AppModel+Billing.swift for the behaviour).
    var entitlement: Entitlement?
    var showSubscribe = false
    var showTerms = !LegalStore().accepted()
    var termsAccepted: LegalAcceptance? = LegalStore().acceptance
    var focusComposer = 0
    let purchases = StoreController.shared
    // The library (see AppModel+Library.swift for the behaviour).
    /// A panel shown in place of the conversation: Memory, Artifacts, Watching and so on.
    var panel: LibraryPanel?
    var projects: [Project] = []
    /// New questions are scoped to this project (its instructions and files go with them).
    var activeProjectId: Int?
    /// Only conversations in this folder are listed; nil lists every one.
    var folderFilter: String?
    var nudges: [Nudge] = []
    var jobs: [ComputeJob] = []
    /// Artifacts from the library (library.artifacts), newest first.
    var libraryArtifacts: [Artifact] = []
    /// The conversation whose artifacts inspector is open.
    var showArtifacts = false

    @ObservationIgnored var openMainWindowAction: (() -> Void)?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var bootstrapped = false

    init() {
        api = OloAPI(token: Keychain.read("session"))
        commons = CommonsLibrary(store: store)
        if let data = UserDefaults.standard.data(forKey: "user.v1") { user = try? JSONDecoder().decode(SessionUser.self, from: data) }
        conversations = store.conversations()
        pending = store.pending()
    }

    var offlineOnly: Bool { UserDefaults.standard.bool(forKey: Prefs.offlineOnly) }
    var canReachCloud: Bool { isOnline && !offlineOnly }

    // MARK: Start-up

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        connectivity.onChange = { [weak self] online in
            guard let self else { return }
            let cameBack = online && !self.isOnline
            self.isOnline = online
            if cameBack { Task { await self.onlineAgain() } }
        }
        connectivity.start()
        await commons.loadFromDisk()
        if canReachCloud {
            await refreshConversations()
            await commons.refreshIfStale()
            await flushPending()
            await refreshLibrary()
        }
        await bootstrapBilling()
    }

    private func onlineAgain() async {
        guard !offlineOnly else { return }
        await refreshConversations()
        await flushPending()
        await commons.refreshIfStale()
        await refreshLibrary()
    }

    // MARK: Window

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let open = openMainWindowAction {
            open()
        } else if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Account

    private func adopt(_ s: SessionResult) {
        api.token = s.token
        Keychain.write("session", s.token)
        user = s.user
        if let data = try? JSONEncoder().encode(s.user) { UserDefaults.standard.set(data, forKey: "user.v1") }
    }

    /// An anonymous workspace with the free allowance, made the first time you ask.
    func ensureSession() async throws {
        if api.token != nil { return }
        adopt(try await api.createSession())
    }

    func requestCode(email: String) async throws {
        try await ensureSession()
        try await api.requestEmailCode(email)
    }

    func verify(email: String, code: String, trainingConsent consent: Bool? = nil) async throws {
        let s = try await api.verifyEmailCode(email: email, code: code)
        adopt(s)
        showSignIn = false
        if let consent {
            UserDefaults.standard.set(consent, forKey: Prefs.trainingConsent)
            await sendTrainingConsent(consent)
        }
        await refreshConversations()
        await refreshEntitlement()
        await refreshLibrary()
    }

    /// Whether this person's conversations may be used to improve Olo and train Zeus.
    /// Off until ticked. Kept on this Mac, and told to helius-olo.io when it knows the
    /// procedure (an older server answers NOT_FOUND, which is ignored).
    var trainingConsent: Bool {
        get { UserDefaults.standard.bool(forKey: Prefs.trainingConsent) }
        set {
            UserDefaults.standard.set(newValue, forKey: Prefs.trainingConsent)
            Task { await sendTrainingConsent(newValue) }
        }
    }

    private func sendTrainingConsent(_ consent: Bool) async {
        guard canReachCloud, api.token != nil else { return }
        do {
            try await api.setTrainingConsent(consent)
        } catch let e as TRPC.RemoteError where e.isNotFound {
            // The server does not record it yet; the choice stays on this Mac.
        } catch {
            banner = "Your training choice is saved on this Mac but could not be sent to helius-olo.io yet."
        }
    }

    func signOut() {
        api.token = nil
        Keychain.write("session", nil)
        user = nil
        entitlement = nil
        UserDefaults.standard.removeObject(forKey: "user.v1")
        conversations.removeAll { $0.serverId != nil }
        projects = []
        activeProjectId = nil
        nudges = []
        jobs = []
        libraryArtifacts = []
        persist()
    }

    func eraseLocalData() {
        store.eraseAll()
        conversations.removeAll()
        pending.removeAll()
        selection = nil
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { banner = "Could not change Open at Login: \(error.localizedDescription)" }
        }
    }

    // MARK: Conversations

    func persist() {
        store.saveConversations(conversations)
        store.savePending(pending)
    }

    func conversation(_ id: UUID?) -> LocalConversation? {
        guard let id else { return nil }
        return conversations.first { $0.id == id }
    }

    func update(_ id: UUID, _ change: (inout LocalConversation) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[i])
    }

    func updateTurn(_ cid: UUID, _ tid: UUID, _ change: (inout Turn) -> Void) {
        update(cid) { c in
            if let j = c.turns.firstIndex(where: { $0.id == tid }) { change(&c.turns[j]) }
        }
    }

    @discardableResult
    func newConversation() -> UUID {
        if let current = conversation(selection), current.turns.isEmpty, current.serverId == nil { return current.id }
        let c = LocalConversation(title: "New conversation")
        conversations.insert(c, at: 0)
        selection = c.id
        panel = nil
        return c.id
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if selection == id { selection = nil }
        persist()
    }

    /// Brings the list in line with helius-olo.io, keeping conversations only on this Mac.
    func refreshConversations() async {
        guard canReachCloud, api.token != nil else { return }
        do {
            let remote = try await api.listConversations()
            var byServer: [Int: Int] = [:]
            for (i, c) in conversations.enumerated() { if let s = c.serverId { byServer[s] = i } }
            for r in remote {
                let updated = ISO8601.parse(r.updatedAt) ?? Date()
                if let i = byServer[r.id] {
                    conversations[i].title = r.title
                    conversations[i].isPinned = r.isPinned
                    conversations[i].folder = r.folder
                    if updated > conversations[i].updatedAt { conversations[i].updatedAt = updated }
                } else {
                    conversations.append(LocalConversation(serverId: r.id, title: r.title, updatedAt: updated, isPinned: r.isPinned, folder: r.folder))
                }
            }
            // Conversations deleted on another device go here too (unless something is being answered in them).
            let live = Set(remote.map(\.id))
            conversations.removeAll { c in
                guard let s = c.serverId else { return false }
                return !live.contains(s) && answering[c.id] == nil
            }
            conversations.sort { $0.updatedAt > $1.updatedAt }
            persist()
        } catch let e as TRPC.RemoteError where e.isUnauthorized {
            banner = "Your session ended. Sign in again to see your conversations."
        } catch {
            // Offline or the service is down: the saved copies stay readable.
        }
    }

    /// Opens a conversation and fetches its messages (the saved copy shows at once).
    func open(_ id: UUID) {
        selection = id
        panel = nil
        guard let c = conversation(id), let sid = c.serverId, canReachCloud, answering[id] == nil else { return }
        Task { await loadMessages(id, serverId: sid) }
    }

    func openServerConversation(_ serverId: Int) {
        if let c = conversations.first(where: { $0.serverId == serverId }) { open(c.id); return }
        let c = LocalConversation(serverId: serverId, title: "Conversation")
        conversations.insert(c, at: 0)
        open(c.id)
    }

    func loadMessages(_ id: UUID, serverId: Int) async {
        guard let msgs = try? await api.messages(conversationId: serverId) else { return }
        update(id) { c in
            // Keep answers made on this Mac (offline or by the Commons) that the server does not have.
            let localOnly = c.turns.filter { $0.serverMessageId == nil && $0.origin != nil && $0.origin != .olo }
            c.turns = msgs.filter { $0.role != "system" }.map(Turn.init(message:)) + localOnly
        }
        persist()
    }

    // MARK: Asking

    /// Asks a question in a conversation; the answer streams into it.
    func ask(_ question: String, attachments: [Attachment] = [], in conversationId: UUID? = nil, searchWeb: Bool = false, useFolders: Bool = false) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty || !attachments.isEmpty else { return }
        let cid = conversationId ?? selection ?? newConversation()
        if conversation(cid) == nil { return }
        guard answering[cid] == nil else { return }
        let userTurn = Turn(role: .user, text: q.isEmpty ? "Explain this." : q, attachments: attachments.map(\.name))
        let answer = Turn(role: .assistant, text: "")
        update(cid) { c in
            c.turns.append(userTurn)
            c.turns.append(answer)
            c.updatedAt = Date()
            if c.turns.count <= 2 && c.title == "New conversation" { c.title = LocalConversation.title(for: userTurn.text) }
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
        answering[cid] = "Thinking"
        tasks[cid] = Task { [weak self] in
            await self?.answer(question: userTurn.text, attachments: attachments, cid: cid, tid: answer.id, searchWeb: searchWeb, useFolders: useFolders)
        }
    }

    func stop(_ cid: UUID) {
        tasks[cid]?.cancel()
    }

    private func finish(_ cid: UUID) {
        answering[cid] = nil
        tasks[cid] = nil
        persist()
    }

    private func answer(question: String, attachments: [Attachment], cid: UUID, tid: UUID, searchWeb: Bool, useFolders: Bool) async {
        defer { finish(cid) }
        var attached = attachments
        if useFolders {
            answering[cid] = "Searching your folders"
            await folders.ensureIndexed()
            for p in folders.search(question) { attached.append(Attachment(kind: .folderPassage, name: p.title, text: p.text)) }
        }
        let composed = MessageComposer.compose(question: question, attachments: attached)
        if !composed.trimmed.isEmpty {
            updateTurn(cid, tid) { $0.notices.append("Only the start of \(composed.trimmed.joined(separator: ", ")) was sent, to keep the question a sensible size.") }
        }
        guard canReachCloud else {
            answerOffline(question: question, content: composed.content, attachments: attached, cid: cid, tid: tid)
            return
        }
        do {
            try await ensureSession()
            try await streamFromOlo(content: composed.content, cid: cid, tid: tid, searchWeb: searchWeb, retryOnAuth: true)
        } catch is CancellationError {
            updateTurn(cid, tid) { $0.notices.append("Stopped.") }
        } catch let f as OloAPI.StreamFailure where f.isQuota {
            let notice = await quotaRefused()
            updateTurn(cid, tid) { t in
                t.text = t.text.isEmpty ? f.message : t.text
                t.notices.append(notice)
            }
        } catch {
            if Task.isCancelled { updateTurn(cid, tid) { $0.notices.append("Stopped.") }; return }
            await fallBack(question: question, content: composed.content, attachments: attached, cid: cid, tid: tid, error: error)
        }
    }

    private func streamFromOlo(content: String, cid: UUID, tid: UUID, searchWeb: Bool, retryOnAuth: Bool) async throws {
        let serverId = conversation(cid)?.serverId
        var outcome = StreamOutcome()
        do {
            let input = OloAPI.AskInput(conversationId: serverId, content: content, grounded: searchWeb,
                                        projectId: activeProjectId, challenge: challengeMode)
            for try await event in api.ask(input) {
                try Task.checkCancellation()
                outcome.apply(event)
                switch event {
                case .start(let id): update(cid) { $0.serverId = id }
                case .delta: updateTurn(cid, tid) { $0.text = outcome.text; $0.origin = .olo }; answering[cid] = "Writing"
                case .status(let stage, let detail): answering[cid] = detail ?? stage
                case .sources(let s): updateTurn(cid, tid) { $0.sources = s }; answering[cid] = "Reading \(s.count) sources"
                case .notice(let m), .cut(let m): updateTurn(cid, tid) { $0.notices.append(m) }
                case .verification(let v): updateTurn(cid, tid) { $0.verification = v; $0.setAnsweredBy(v.answeredBy) }
                case .answeredBy(let w, let p, let ver): updateTurn(cid, tid) { $0.setAnsweredBy(AnsweredBy(writer: w, provider: p, verifier: ver)) }
                case .followUps(let q): updateTurn(cid, tid) { $0.followUps = q }
                case .answerComplete(_, let mid):
                    updateTurn(cid, tid) { $0.serverMessageId = mid }
                    answering[cid] = "Checking each sentence"
                case .artifact(let a):
                    updateTurn(cid, tid) { t in
                        if let i = t.artifacts.firstIndex(where: { $0.id == a.id }) { t.artifacts[i] = a } else { t.artifacts.append(a) }
                    }
                    answering[cid] = "Checking the file"
                case .references(let r): updateTurn(cid, tid) { $0.references = r }
                case .memories(let m): updateTurn(cid, tid) { $0.memories = m }
                case .truncated(_, let m): updateTurn(cid, tid) { $0.notices.append(m) }
                case .error(let message, _, let code):
                    throw OloAPI.StreamFailure(message: message, code: code, httpStatus: code == "quota_exceeded" ? 402 : 500)
                default: break
                }
            }
        } catch let f as OloAPI.StreamFailure where f.isUnauthorized && retryOnAuth {
            // The saved session expired: start a fresh one once and ask again.
            api.token = nil
            Keychain.write("session", nil)
            try await ensureSession()
            try await streamFromOlo(content: content, cid: cid, tid: tid, searchWeb: searchWeb, retryOnAuth: false)
            return
        } catch {
            // The host closes long connections now and then. If text had arrived, the answer is being
            // saved on the server: fetch the saved copy rather than failing.
            if !outcome.text.isEmpty, !(error is CancellationError), !(error is OloAPI.StreamFailure) {
                await recoverSavedAnswer(cid: cid, tid: tid, partial: outcome)
                return
            }
            throw error
        }
        if !outcome.completed && !outcome.text.isEmpty {
            await recoverSavedAnswer(cid: cid, tid: tid, partial: outcome)
        }
    }

    /// Polls for the saved reply for up to two minutes, keeping the partial text on screen meanwhile.
    private func recoverSavedAnswer(cid: UUID, tid: UUID, partial: StreamOutcome) async {
        guard let sid = conversation(cid)?.serverId ?? partial.conversationId else { return }
        answering[cid] = "Finishing"
        for delay in [1.0, 2, 3, 5, 8, 13, 20, 30, 40] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            guard let msgs = try? await api.messages(conversationId: sid), let last = msgs.last(where: { $0.role == "assistant" }) else { continue }
            if last.content.count >= partial.text.count {
                updateTurn(cid, tid) { t in
                    t.text = last.content
                    t.serverMessageId = last.id
                    if let v = last.verification { t.verification = v; t.setAnsweredBy(v.answeredBy) }
                    if let s = last.sources, !s.isEmpty { t.sources = s }
                }
                return
            }
        }
        updateTurn(cid, tid) { $0.notices.append("The connection closed before the end of the answer. Reopen the conversation in a minute to see the saved copy.") }
    }

    /// helius-olo.io failed: the Commons' own service, then offline quotes.
    private func fallBack(question: String, content: String, attachments: [Attachment], cid: UUID, tid: UUID, error: Error) async {
        // A question about attached text needs Olo itself; the Commons only answers from its own facts.
        if attachments.isEmpty {
            answering[cid] = "Asking Olo Commons"
            if let a = try? await CommonsAnswer.ask(question), a.covered != false {
                updateTurn(cid, tid) { t in
                    t.text = a.answer
                    t.origin = .commons
                    t.sources = a.asSources
                    t.verification = a.asVerification
                    t.setAnsweredBy(a.attribution)
                    if let n = a.notice { t.notices.append(n) }
                    t.notices.append("helius-olo.io could not be reached (\(error.localizedDescription)), so Olo Commons answered.")
                }
                return
            }
        }
        answerOffline(question: question, content: content, attachments: attachments, cid: cid, tid: tid)
        updateTurn(cid, tid) { $0.notices.insert("Olo could not be reached (\(error.localizedDescription)).", at: 0) }
    }

    /// No connection: quote what is saved here and queue the question.
    private func answerOffline(question: String, content: String, attachments: [Attachment], cid: UUID, tid: UUID) {
        var passages: [Passage] = []
        // Attached files come first: a question about a document is answered from it.
        for a in attachments {
            let pieces = Chunker.chunks(a.text)
            let idx = SearchIndex(pieces, title: { _ in a.name }, text: { $0 })
            passages += idx.search(question, limit: 3).map { Passage(title: a.name, text: $0.doc, url: "", origin: "Attached") }
        }
        passages += folders.search(question, limit: 3)
        passages += commons.search(question, limit: 6)
        let quoted = QuotedAnswer.compose(question: question, passages: passages)
        updateTurn(cid, tid) { t in
            t.text = quoted.text
            t.origin = .offline
            t.sources = quoted.sources
        }
        if !offlineOnly, UserDefaults.standard.object(forKey: Prefs.askPendingWhenOnline) as? Bool ?? true {
            pending.append(PendingQuestion(question: question, content: content, localConversation: cid))
            updateTurn(cid, tid) { $0.notices.append("Olo will ask this properly, with checked sources, when the Mac is back online.") }
        }
    }

    /// Asks the questions queued offline, each in the conversation it was asked in.
    func flushPending() async {
        guard canReachCloud, !pending.isEmpty else { return }
        let queue = pending
        pending.removeAll()
        persist()
        for p in queue {
            guard conversation(p.localConversation) != nil, answering[p.localConversation] == nil else { continue }
            let cid = p.localConversation
            let t = Turn(role: .assistant, text: "")
            update(cid) { c in c.turns.append(t); c.updatedAt = Date() }
            answering[cid] = "Asking now that you are online"
            do {
                try await ensureSession()
                try await streamFromOlo(content: p.content, cid: cid, tid: t.id, searchWeb: false, retryOnAuth: true)
                updateTurn(cid, t.id) { $0.notices.insert("Asked when the connection returned.", at: 0) }
            } catch {
                update(cid) { c in c.turns.removeAll { $0.id == t.id } }
                pending.append(p)
            }
            answering[cid] = nil
        }
        persist()
    }
}

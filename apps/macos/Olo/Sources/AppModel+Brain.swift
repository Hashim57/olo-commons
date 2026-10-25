import AppKit
import OloKit

/// The Olo brain ("ask once, then remember", with a per chat switch) and private chats
/// (sent with private: true, never synced, kept encrypted on this Mac). The stored
/// properties live in AppModel.swift; everything else is here.
extension AppModel {
    // MARK: The brain default

    /// Signed in with an email: the default lives on the account. Otherwise it stays on this Mac.
    var brainChoiceOnAccount: Bool { !(user?.isAnonymous ?? true) }

    /// Reads the account default from auth.me. When the account has none yet but a choice was made
    /// on this Mac (before signing in), that choice becomes the account default.
    func refreshBrainSharing() async {
        guard canReachCloud, api.token != nil, brainChoiceOnAccount else { return }
        guard let state = try? await api.brainSharingState() else { return }
        switch state {
        case .chosen(let share):
            brainSharing = share
            UserDefaults.standard.set(share, forKey: Prefs.brainSharing)
        case .notAsked:
            if let local = UserDefaults.standard.object(forKey: Prefs.brainSharing) as? Bool {
                brainSharing = local
                _ = try? await api.setBrainSharing(local)
            } else {
                brainSharing = nil
            }
        case .unknown:
            break
        }
        considerBrainChoice()
    }

    /// Shows the one-time card when no default has been chosen, once per launch and never over the terms.
    func considerBrainChoice() {
        guard brainSharing == nil, !showTerms, !brainChoiceAsked else { return }
        brainChoiceAsked = true
        showBrainChoice = true
    }

    /// Saves the default: on this Mac always, and on the account when signed in (auth.setBrainSharing).
    func setBrainSharing(_ share: Bool) {
        brainSharing = share
        showBrainChoice = false
        UserDefaults.standard.set(share, forKey: Prefs.brainSharing)
        guard brainChoiceOnAccount, canReachCloud, api.token != nil else { return }
        Task {
            do {
                try await api.setBrainSharing(share)
            } catch let e as TRPC.RemoteError where e.isNotFound || e.code == "PRECONDITION_FAILED" {
                // An older server, or not an account: the choice stays on this Mac.
            } catch {
                banner = "Your Olo brain choice is saved on this Mac but could not be sent to helius-olo.io yet."
            }
        }
    }

    /// Whether this chat's questions go to the brain: never for a private chat, otherwise the
    /// chat's own switch, otherwise the default (off until chosen).
    func brainEnabled(for cid: UUID) -> Bool {
        guard let c = conversation(cid), !c.isPrivate else { return false }
        return c.addToBrain ?? brainSharing ?? false
    }

    func setAddToBrain(_ cid: UUID, _ on: Bool) {
        guard conversation(cid)?.isPrivate == false else { return }
        update(cid) { $0.addToBrain = on }
        persist()
    }

    func openBrain() {
        NSWorkspace.shared.open(BrainLinks.view)
    }

    /// The fallback path (Olo Commons answered because helius-olo.io could not be reached): the Mac
    /// tells olo-brain-ask itself, with the Commons atoms that answered. Failure changes nothing.
    func shareWithBrainDirectly(question: String, answer: CommonsAnswer, cid: UUID, tid: UUID) {
        guard brainEnabled(for: cid) else { return }
        let atoms = (answer.passages ?? []).map(\.id)
        guard let body = BrainAsk.body(question: question, client: "macos", atoms: atoms, answered: !answer.answer.isEmpty) else { return }
        Task { [weak self] in
            guard let result = await BrainAsk.send(body) else { return }
            self?.updateTurn(cid, tid) { $0.brainStatus = result.status }
            self?.persist()
        }
    }

    // MARK: Private chats

    /// Makes a chat private, or not, before anything is sent in it. A chat already saved on
    /// helius-olo.io cannot become private (it is there already); start a new private chat instead.
    func setPrivate(_ cid: UUID, _ on: Bool) {
        guard let c = conversation(cid) else { return }
        guard c.turns.isEmpty, c.serverId == nil else {
            banner = on ? "This conversation has started already. Start a new private chat with File > New Private Chat."
                        : "A private chat stays private. Start a new conversation to share."
            return
        }
        update(cid) { conv in
            conv.isPrivate = on
            conv.addToBrain = on ? false : nil
        }
        persist()
    }

    /// A new private chat: answered in the cloud, saved only on this Mac, encrypted.
    @discardableResult
    func newPrivateConversation(title: String = "New conversation", select: Bool = true) -> UUID {
        let c = LocalConversation(title: title, isPrivate: true, addToBrain: false)
        conversations.insert(c, at: 0)
        if select {
            selection = c.id
            panel = nil
        }
        persist()
        return c.id
    }

    /// Writes every private chat to the encrypted store. The Keychain key is made the first time
    /// there is something private to keep.
    func savePrivateConversations() {
        let privateChats = conversations.filter(\.isPrivate)
        if privateStore == nil {
            guard !privateChats.isEmpty else { return }
            do {
                privateStore = try PrivateStore.appSupport(createKey: true)
            } catch {
                banner = "Private chats cannot be kept on this Mac: \(error.localizedDescription)"
                return
            }
        }
        guard let ps = privateStore else { return }
        do {
            try ps.save(privateChats)
        } catch {
            banner = "Private chats could not be saved on this Mac: \(error.localizedDescription)"
        }
    }
}

import AppKit
import OloKit

/// The panels that take the place of a conversation in the main window.
enum LibraryPanel: String, CaseIterable, Identifiable {
    case build, memory, artifacts, watching, zeus, skills, connectors, jobs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .build: return "Build with Olo"
        case .memory: return "Memory"
        case .artifacts: return "Artifacts"
        case .watching: return "Watching"
        case .zeus: return "What Zeus Knows"
        case .skills: return "Skills"
        case .connectors: return "Connectors"
        case .jobs: return "Analyses"
        }
    }

    var symbol: String {
        switch self {
        case .build: return "hammer"
        case .memory: return "brain"
        case .artifacts: return "doc.richtext"
        case .watching: return "eye"
        case .zeus: return "point.3.connected.trianglepath.dotted"
        case .skills: return "sparkles"
        case .connectors: return "link"
        case .jobs: return "gauge.with.dots.needle.33percent"
        }
    }
}

/// The library: pins, folders, projects, nudges, share links, edits, fixes, watches and
/// analyses. Every call here is the same tRPC procedure the web and iPhone call.
extension AppModel {
    // MARK: Refresh

    /// Projects, nudges and the library's artifacts, fetched together after sign-in and when online again.
    func refreshLibrary() async {
        guard canReachCloud, api.token != nil else { return }
        await refreshProjects()
        await refreshNudges()
    }

    func refreshProjects() async {
        guard canReachCloud, api.token != nil else { return }
        if let list = try? await api.listProjects() {
            projects = list.filter { !$0.isArchived }
            if let active = activeProjectId, !projects.contains(where: { $0.id == active }) { activeProjectId = nil }
        }
    }

    func refreshNudges() async {
        guard canReachCloud, api.token != nil else { return }
        if let list = try? await api.listNudges() { nudges = list }
    }

    func refreshLibraryArtifacts() async {
        guard canReachCloud, api.token != nil else { return }
        if let list = try? await api.listArtifacts() { libraryArtifacts = list }
    }

    /// The server could not do it: one sentence in the banner.
    func report(_ error: Error, doing what: String) {
        banner = "Could not \(what): \(error.localizedDescription)"
    }

    // MARK: Challenge mode

    /// "Challenge me": Olo disagrees first when the evidence points the other way. Kept on this Mac, sent with every question.
    var challengeMode: Bool {
        get { UserDefaults.standard.bool(forKey: Prefs.challengeMode) }
        set { UserDefaults.standard.set(newValue, forKey: Prefs.challengeMode) }
    }

    // MARK: Pins and folders

    /// Every folder the listed conversations use, sorted.
    var conversationFolders: [String] {
        Array(Set(conversations.compactMap { $0.folder }.filter { !$0.isEmpty })).sorted { $0.lowercased() < $1.lowercased() }
    }

    func setPinned(_ id: UUID, _ pinned: Bool) async {
        guard let c = conversation(id) else { return }
        update(id) { $0.isPinned = pinned }
        persist()
        guard let sid = c.serverId, canReachCloud else { return }
        do {
            try await api.updateOrganization(OloAPI.OrganizationInput(conversationId: sid, folder: c.folder, folderColor: nil, isPinned: pinned))
        } catch {
            update(id) { $0.isPinned = !pinned }
            report(error, doing: pinned ? "pin the conversation" : "unpin the conversation")
        }
    }

    /// Moves a conversation into a folder (nil takes it out of its folder).
    func setFolder(_ id: UUID, _ folder: String?) async {
        guard let c = conversation(id) else { return }
        var target: String?
        if let cleaned = folder?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty { target = String(cleaned.prefix(64)) }
        let before = c.folder
        update(id) { $0.folder = target }
        persist()
        guard let sid = c.serverId, canReachCloud else { return }
        do {
            try await api.updateOrganization(OloAPI.OrganizationInput(conversationId: sid, folder: target, folderColor: nil, isPinned: c.isPinned))
        } catch {
            update(id) { $0.folder = before }
            report(error, doing: "move the conversation")
        }
    }

    /// Deletes a conversation on helius-olo.io and on this Mac.
    func deleteEverywhere(_ id: UUID) async {
        guard let c = conversation(id) else { return }
        if let sid = c.serverId {
            guard canReachCloud else { banner = "Deleting on helius-olo.io needs a connection. \"Delete from This Mac\" works offline."; return }
            do { try await api.deleteConversation(id: sid) } catch { report(error, doing: "delete the conversation"); return }
        }
        delete(id)
    }

    // MARK: Projects

    func createProject(name: String, description: String?, instructions: String?, kind: String) async {
        guard canReachCloud else { banner = "Projects need a connection."; return }
        do {
            try await ensureSession()
            let p = try await api.createProject(OloAPI.ProjectCreateInput(name: name, description: description, instructions: instructions, kind: kind))
            projects.insert(p, at: 0)
            activeProjectId = p.id
        } catch {
            report(error, doing: "create the project")
        }
    }

    func deleteProject(_ id: Int) async {
        guard canReachCloud else { banner = "Projects need a connection."; return }
        do {
            try await api.deleteProject(id: id)
            projects.removeAll { $0.id == id }
            if activeProjectId == id { activeProjectId = nil }
        } catch {
            report(error, doing: "delete the project")
        }
    }

    var activeProject: Project? { projects.first { $0.id == activeProjectId } }

    // MARK: Nudges

    func markNudge(_ n: Nudge, status: String) async {
        nudges.removeAll { $0.id == n.id }
        try? await api.markNudge(id: n.id, status: status)
    }

    /// Opens what a nudge is about: the thread, or the panel for a changed claim or a finished build.
    func openNudge(_ n: Nudge) {
        Task { await markNudge(n, status: "seen") }
        if let cid = n.conversationId { openServerConversation(cid); return }
        switch n.kind {
        case "claim_changed": panel = .watching
        case "build_ready", "build_failed": panel = .artifacts
        default: break
        }
    }

    // MARK: Share links

    /// A share link for a conversation (library.share, subjectType "conversation"), copied to the clipboard.
    func copyShareLink(for id: UUID) async {
        guard let c = conversation(id), let sid = c.serverId else { banner = "Only conversations saved on helius-olo.io can be shared."; return }
        await copyShareLink(subjectType: "conversation", subjectId: String(sid), label: c.title)
    }

    func copyShareLink(subjectType: String, subjectId: String, label: String?) async {
        guard canReachCloud else { banner = "Share links need a connection."; return }
        do {
            let share = try await api.createShare(OloAPI.ShareInput(subjectType: subjectType, subjectId: subjectId, label: label.map { String($0.prefix(120)) }))
            let url = share.url(base: api.base)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            banner = "Share link copied. Anyone with it can read; revoke it from Artifacts > Share links."
        } catch {
            report(error, doing: "make a share link")
        }
    }

    // MARK: Edit in place and fixes

    /// Applies a rewritten passage (chat.editPassage) to the turn, then refetches the thread as the web does.
    func applyEdit(_ result: EditPassageResult, cid: UUID, tid: UUID) async {
        updateTurn(cid, tid) { t in
            t.text = result.content
            t.notices.append("A passage was rewritten. The verdicts below are from before the edit; use Fix flagged sentences to re-check.")
        }
        persist()
        if let sid = conversation(cid)?.serverId { await loadMessages(cid, serverId: sid) }
    }

    /// Rewrites only the sentences Zeus flagged, from fresh research, and re-checks them (/api/chat/fix).
    func fixFlagged(cid: UUID, tid: UUID) async {
        guard let c = conversation(cid), let sid = c.serverId, let t = c.turns.first(where: { $0.id == tid }), let mid = t.serverMessageId else {
            banner = "This answer is not saved on helius-olo.io yet, so it cannot be fixed there."
            return
        }
        guard canReachCloud, answering[cid] == nil else { return }
        answering[cid] = "Researching the flagged sentences"
        defer { answering[cid] = nil }
        do {
            for try await event in api.fixFlagged(conversationId: sid, messageId: mid) {
                switch event {
                case .status(let stage, let detail): answering[cid] = detail ?? stage
                case .fixed(let r):
                    updateTurn(cid, tid) { turn in
                        turn.text = r.content
                        if let v = r.verification { turn.verification = v }
                        if !r.sources.isEmpty { turn.sources = r.sources }
                        turn.notices.append("Fixed: \(r.summary).")
                    }
                    persist()
                case .error(let m): banner = m
                }
            }
        } catch {
            report(error, doing: "fix the flagged sentences")
        }
    }

    // MARK: Watching

    /// Watches every filed claim of an answer (monitors.watch), as the web's Watch button does.
    func watch(_ turn: Turn) async {
        let ids = (turn.verification?.claims ?? []).compactMap(\.claimId)
        guard !ids.isEmpty else { banner = "None of these claims was filed in the graph, so there is nothing to watch yet."; return }
        guard canReachCloud else { banner = "Watching needs a connection."; return }
        var watched = 0
        var failure: String?
        for id in ids {
            do { _ = try await api.watchClaim(claimId: id); watched += 1 } catch { failure = error.localizedDescription }
        }
        if watched > 0 {
            banner = "Watching \(watched) claim\(watched == 1 ? "" : "s"). Olo will tell you if the evidence changes."
        } else if let failure {
            banner = "Could not watch: \(failure)"
        }
    }

    // MARK: Analyses (compute jobs)

    /// Runs the question as a background analysis (compute.start) and polls until it finishes;
    /// the result lands in the conversation as an answer.
    func analyse(_ prompt: String, in conversationId: UUID?) {
        let q = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let cid = conversationId ?? selection ?? newConversation()
        guard conversation(cid) != nil, answering[cid] == nil else { return }
        let userTurn = Turn(role: .user, text: q)
        let answer = Turn(role: .assistant, text: "", origin: .olo)
        update(cid) { c in
            c.turns.append(userTurn)
            c.turns.append(answer)
            c.updatedAt = Date()
            if c.turns.count <= 2 && c.title == "New conversation" { c.title = LocalConversation.title(for: q) }
        }
        answering[cid] = "Starting the analysis"
        Task { [weak self] in
            guard let self else { return }
            defer { self.answering[cid] = nil; self.persist() }
            guard self.canReachCloud else {
                self.updateTurn(cid, answer.id) { $0.notices.append("Analyses run on helius-olo.io and need a connection.") }
                return
            }
            do {
                try await self.ensureSession()
                var job = try await self.api.startCompute(prompt: q, conversationId: self.conversation(cid)?.serverId)
                self.jobs.insert(job, at: 0)
                while !job.isFinished {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    job = try await self.api.computeJob(id: job.id)
                    self.answering[cid] = "\(job.statusLine) (\(Int((job.fraction * 100).rounded()))%)"
                    if let i = self.jobs.firstIndex(where: { $0.id == job.id }) { self.jobs[i] = job }
                }
                self.updateTurn(cid, answer.id) { t in
                    t.text = job.result ?? ""
                    switch job.status {
                    case "succeeded": t.notices.append("A background analysis, not checked sentence by sentence by Zeus.")
                    case "cancelled": t.notices.append("The analysis was cancelled.")
                    default: t.notices.append(job.error.map { "The analysis failed: \($0)" } ?? "The analysis failed.")
                    }
                }
            } catch let e as TRPC.RemoteError where e.code == "FORBIDDEN" {
                self.updateTurn(cid, answer.id) { $0.notices.append(e.message) }
                await self.refreshEntitlement()
            } catch {
                self.updateTurn(cid, answer.id) { $0.notices.append("The analysis could not run: \(error.localizedDescription)") }
            }
        }
    }

    func refreshJobs() async {
        guard canReachCloud, api.token != nil else { return }
        if let list = try? await api.listComputeJobs() { jobs = list }
    }

    func cancelJob(_ id: String) async {
        do {
            try await api.cancelCompute(id: id)
            if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].cancelRequested = true }
        } catch {
            report(error, doing: "cancel the analysis")
        }
    }
}

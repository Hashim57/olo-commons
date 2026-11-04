import AppKit
import OloKit

/// The panels that take the place of a conversation in the main window.
enum LibraryPanel: String, CaseIterable, Identifiable {
    case build, browser, memory, artifacts, watching, zeus, skills, connectors, jobs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .build: return "Build with Olo"
        case .browser: return "Browser"
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
        case .browser: return "safari"
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

    /// Opens a web address, or runs a page Olo built, in the built-in browser.
    func openInBrowser(_ request: BrowserRequest) {
        browserRequest = request
        panel = .browser
    }

    /// Opens a file in the Artifacts panel, selected, from its card in the thread.
    func openArtifact(_ a: Artifact) {
        pendingArtifactSelection = a.id
        panel = .artifacts
    }

    /// An answer that is itself the document someone asked for (a report, a plan, a case) becomes a
    /// file in the thread, so it can be opened, exported as PDF or Word and found in Artifacts later.
    /// Only when the question asked for a document or a build and the answer has the shape of one.
    func fileAnswerAsDocument(question: String, cid: UUID, tid: UUID) {
        guard buildJobs[tid] == nil, let c = conversation(cid), let t = c.turns.first(where: { $0.id == tid }), t.artifacts.isEmpty,
              !ReplyFile.endsInsideFence(t.text),
              ExportHints.hint(for: question) != nil || QuotedAnswer.looksLikeBuildRequest(question),
              MarkdownBlocks.isStructured(t.text), t.text.count >= 400 else { return }
        let title = MarkdownBlocks.title(of: t.text) ?? String(question.prefix(60))
        let base = TranscriptExport.safeFilename(title, fallback: "document").replacingOccurrences(of: " ", with: "-").lowercased()
        let a = Artifact(id: "local-" + UUID().uuidString.lowercased(), kind: "markdown", language: "markdown", title: title,
                         filename: base + ".md", code: t.text, validated: true, conversationId: c.serverId)
        updateTurn(cid, tid) { $0.artifacts.append(a) }
    }

    // MARK: Background builds

    /// A build the server moved to the background (the "truncated" stream event) finishes minutes
    /// later. Until now the thread only showed the notice and the file appeared on the next sign-in.
    /// With the job id the app polls builds.get every 10 seconds (up to 20 minutes), shows the stage
    /// in the notice, and puts the artifact into the thread (and the library) when it is done, or
    /// reports the failure. Without a job id it watches the library for the new artifact instead.
    /// So building a site or an app is one request, not two.
    func watchBackgroundBuild(jobId: String?, cid: UUID, tid: UUID) {
        let known = Set(libraryArtifacts.map(\.id))
        let serverId = conversation(cid)?.serverId
        let marker = "background build"
        Task { [weak self] in
            // Every 3 seconds for the first 15 minutes (the build card moves as the file arrives),
            // every 10 after that, 20 minutes in all.
            var kicks = 0
            let started = Date()
            while Date().timeIntervalSince(started) < 20 * 60 {
                let fast = Date().timeIntervalSince(started) < 15 * 60
                try? await Task.sleep(nanoseconds: fast ? 3_000_000_000 : 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.canReachCloud, self.api.token != nil else { continue }
                if let jobId {
                    guard let job = try? await self.api.buildJob(id: jobId) else { continue }
                    self.buildJobs[tid] = job
                    // Still queued after a few seconds: the server's own start never left. Start it here.
                    if job.status == "queued", kicks < 2, Date().timeIntervalSince(started) > Double(6 * (kicks + 1)) {
                        kicks += 1
                        await self.api.kickBuild(id: jobId)
                    }
                    // Only a finished build names who answered; a failed one said nothing.
                    if let a = job.finishedAnsweredBy { self.updateTurn(cid, tid) { $0.setAnsweredBy(a) } }
                    if let text = job.finishedAnswer {
                        // The server finished the cut answer in place: show the whole text.
                        self.updateTurn(cid, tid) { t in
                            t.buildJobId = nil
                            t.text = text
                            t.notices.removeAll { $0.localizedCaseInsensitiveContains(marker) || $0.localizedCaseInsensitiveContains("finishing it in the background") || $0.localizedCaseInsensitiveContains("length limit") }
                            t.notices.append("Olo finished this answer in the background.")
                        }
                        self.buildJobs[tid] = nil
                        await self.clearBuildNudges()
                        return
                    }
                    if let a = job.artifact, job.status == "succeeded" {
                        self.updateTurn(cid, tid) { t in
                            t.buildJobId = nil
                            if let i = t.artifacts.firstIndex(where: { $0.id == a.id }) { t.artifacts[i] = a } else { t.artifacts.append(a) }
                            t.notices.removeAll { $0.localizedCaseInsensitiveContains(marker) }
                            if let s = job.summary, !s.isEmpty, t.text.isEmpty || ReplyFile.endsInsideFence(t.text) { t.text = s }
                            t.origin = .olo
                        }
                        await self.refreshLibraryArtifacts()
                        await self.clearBuildNudges()
                        self.persist()
                        return
                    }
                    if job.isFinished {
                        self.updateTurn(cid, tid) { t in
                            t.buildJobId = nil
                            t.notices.removeAll { $0.localizedCaseInsensitiveContains(marker) }
                            if t.text.isEmpty {
                                t.text = job.status == "cancelled" ? "The build was cancelled." : "The build did not finish."
                            }
                        }
                        await self.clearBuildNudges()
                        self.persist()
                        return
                    }
                    continue
                }
                guard let list = try? await self.api.listArtifacts() else { continue }
                self.libraryArtifacts = list
                // Newest first; one from this thread when the server says which, else any new one.
                if let a = list.first(where: { !known.contains($0.id) && ($0.conversationId == nil || serverId == nil || $0.conversationId == serverId) }) {
                    self.updateTurn(cid, tid) { t in
                        if !t.artifacts.contains(where: { $0.id == a.id }) { t.artifacts.append(a) }
                        t.notices.removeAll { $0.localizedCaseInsensitiveContains(marker) }
                        t.notices.append("The background build finished: \(a.title) is below and in Artifacts.")
                    }
                    await self.clearBuildNudges()
                    return
                }
            }
            guard let self else { return }
            self.updateTurn(cid, tid) { $0.notices.append("The background build is taking longer than 20 minutes. It will appear in Artifacts when it is ready.") }
        }
    }

    /// Starts a background build for a request to make a whole site, app or guide, and follows it in
    /// the thread with the build card. False when this server cannot run background builds, so the
    /// caller streams instead.
    func startBackgroundBuild(prompt: String, cid: UUID, tid: UUID) async throws -> Bool {
        answering[cid] = "Starting the build"
        let job: BuildJob
        do {
            job = try await api.startBuild(OloAPI.StartBuildInput(prompt: prompt, conversationId: conversation(cid)?.serverId, projectId: activeProjectId))
        } catch let e as TRPC.RemoteError where e.code == "PRECONDITION_FAILED" || e.isNotFound {
            return false
        }
        buildJobs[tid] = job
        updateTurn(cid, tid) { t in t.origin = .olo; t.buildJobId = job.id }
        persist()
        watchBackgroundBuild(jobId: job.id, cid: cid, tid: tid)
        await refreshEntitlement()
        return true
    }

    /// The build card's Cancel: asks the server to stop, and shows it at once.
    func cancelBackgroundBuild(tid: UUID) {
        guard var job = buildJobs[tid], job.isRunning else { return }
        job.status = "cancelled"
        buildJobs[tid] = job
        Task { try? await api.cancelBuild(id: job.id) }
    }

    /// Follows again every build a thread was waiting on when Olo was last quit, so its card and
    /// its file come back instead of disappearing.
    func resumeBackgroundBuilds() {
        for c in conversations {
            for t in c.turns {
                guard let jobId = t.buildJobId, buildJobs[t.id] == nil else { continue }
                watchBackgroundBuild(jobId: jobId, cid: c.id, tid: t.id)
            }
        }
    }

    /// The failed card's Try again: the same request as a new job, followed by the same card.
    func retryBackgroundBuild(tid: UUID) {
        guard let job = buildJobs[tid], job.canRetry, let prompt = job.prompt,
              let cid = conversations.first(where: { c in c.turns.contains { $0.id == tid } })?.id else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                if try await self.startBackgroundBuild(prompt: prompt, cid: cid, tid: tid) == false {
                    self.banner = "Background builds are not available on this server right now."
                }
            } catch let failure {
                self.banner = "The build could not be started again: \(failure.localizedDescription)"
            }
            self.answering[cid] = nil
        }
    }

    /// The build nudges are about the build the thread just showed, so they need no bell.
    private func clearBuildNudges() async {
        for n in (try? await api.listNudges()) ?? [] where n.kind == "build_ready" || n.kind == "build_failed" {
            await markNudge(n, status: "seen")
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

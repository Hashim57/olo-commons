import Foundation
import OloKit
import UIKit

/// The plan, the conversation as a document, share links and deep links: what the newer screens
/// need from the model. The stored properties live in AppModel.swift.
extension AppModel {
    // MARK: Plan

    /// Connects the App Store controller to the account: purchases are redeemed with this
    /// session's token, and every entitlement the server returns is shown at once.
    func bootstrapBilling() async {
        purchases.redeem = { [weak self] transactionId, productId in
            guard let self else { throw OloAPI.StreamFailure(message: "Olo is closing.", code: nil, httpStatus: 0) }
            try await self.ensureSession()
            return try await self.api.redeemApplePurchase(transactionId: transactionId, productId: productId)
        }
        purchases.onEntitlement = { [weak self] e in self?.entitlement = e }
        await refreshEntitlement()
    }

    /// Asks helius-olo.io what this account may do now. Quiet on failure: the last answer stays.
    func refreshEntitlement() async {
        guard api.token != nil else { return }
        if let e = try? await api.fetchEntitlement() { entitlement = e }
    }

    var planName: String { entitlement?.planName ?? "Free" }
    var isSubscribed: Bool { entitlement?.subscribed ?? false }

    /// The banner above the composer when the allowance is spent, or nil when sending is allowed.
    var quotaBanner: String? {
        guard let e = entitlement, !e.canSendMessage else { return nil }
        if let refill = e.refillsAtDate, refill <= Date() { return nil }
        if e.isFree { return BillingText.freeMessagesSpent(refillsAt: e.refillsAtDate) }
        return BillingText.planMessagesSpent(plan: e.planName, refillsAt: e.refillsAtDate)
    }

    // MARK: The conversation as a document

    /// The conversation on screen in the form OloKit's exporters read, the same as the Mac's.
    var exportConversation: LocalConversation {
        let turns = items.filter { !$0.text.isEmpty }.map { item in
            Turn(role: item.role == "user" ? .user : .assistant, text: item.text, verification: item.verification, sources: item.sources)
        }
        let saved = conversations.first { $0.id == conversationId }?.title
        let title = saved ?? LocalConversation.title(for: items.first?.text ?? "Conversation")
        return LocalConversation(serverId: conversationId, title: title, turns: turns, isPrivate: isPrivate)
    }

    /// A link anyone can read (library.share), copied to the clipboard. Returns what to tell the person.
    func copyShareLink(subjectType: String, subjectId: String, label: String?) async -> String {
        do {
            let share = try await api.createShare(OloAPI.ShareInput(subjectType: subjectType, subjectId: subjectId, label: label.map { String($0.prefix(120)) }))
            UIPasteboard.general.string = share.url(base: api.base).absoluteString
            return "Share link copied. Anyone with it can read."
        } catch {
            return "The share link could not be made: \(error.localizedDescription)"
        }
    }

    /// A cut answer that the server finished in the background: the whole text replaces the part.
    func finishAnswer(_ id: UUID, with text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].text = text
        items[i].buildJobId = nil
    }

    // MARK: Links into the app

    /// olo://ask?q=..., olo://chat/42 and olo://connected (where the browser lands after a
    /// connector's consent page), read by the same parser as the Mac.
    func handle(url: URL) {
        guard let link = LinkPolicy.parse(url) else { return }
        switch link {
        case .ask(let q):
            if !q.isEmpty { ask(q) }
        case .conversation(let id):
            if let c = conversations.first(where: { $0.id == id }) { Task { await open(c) } }
        case .connected:
            connectorReturns += 1
        case .home:
            break
        }
    }
}

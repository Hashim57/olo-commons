import AppKit
import OloKit

/// Terms acceptance and the plan: what AppModel needs for the "Before you start"
/// sheet, the subscription sheet and the composer banner. The stored properties live
/// in AppModel.swift; everything else is here.
extension AppModel {
    // MARK: Terms

    /// Records agreement to the current terms and lets the person through.
    func acceptTerms() {
        termsAccepted = LegalStore().record()
        showTerms = false
    }

    // MARK: Plan

    /// Connects the StoreKit controller to the account: purchases are redeemed with this
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
        guard isOnline, !UserDefaults.standard.bool(forKey: Prefs.offlineOnly), api.token != nil else { return }
        do {
            entitlement = try await api.fetchEntitlement()
        } catch let e as TRPC.RemoteError where e.isNotFound {
            // An older server without billing procedures: nothing to show.
        } catch {
            // Offline or the service is down: keep what we knew.
        }
    }

    /// The server refused a question for want of allowance. Returns the notice for the turn
    /// and puts the app in the right state: sign-in for an anonymous workspace, the plan
    /// banner for an account.
    func quotaRefused() async -> String {
        if user?.isAnonymous ?? true {
            showSignIn = true
            return "Sign in with your email to keep going on the same account as the web and iPhone."
        }
        await refreshEntitlement()
        var e = entitlement ?? Entitlement()
        if e.canSendMessage {
            // The server just said no, whatever the summary says: show the banner until it refills.
            e.canSendMessage = false
            if e.blockedReason == nil { e.blockedReason = "quota_exceeded" }
        }
        entitlement = e
        if e.isFree { return "Your free messages for today are used up. Subscribe to keep going, or wait for them to refill." }
        return BillingText.planMessagesSpent(plan: e.planName, refillsAt: e.refillsAtDate)
    }

    /// The banner above the composer, or nil when sending is allowed.
    var quotaBanner: String? {
        guard let e = entitlement, !e.canSendMessage else { return nil }
        if let refill = e.refillsAtDate, refill <= Date() { return nil }
        if e.isFree { return BillingText.freeMessagesSpent(refillsAt: e.refillsAtDate) }
        return BillingText.planMessagesSpent(plan: e.planName, refillsAt: e.refillsAtDate)
    }

    /// "Plan: Free", "Plan: Starter".
    var planLine: String { "Plan: \(entitlement?.planName ?? "Free")" }

    var isSubscribed: Bool { entitlement?.subscribed ?? false }

    /// Opens the subscription sheet on the main window (from Settings, the menu or the banner).
    func openSubscribe() {
        showSubscribe = true
        showMainWindow()
    }

    /// Opens the terms sheet again, to read them.
    func reopenTerms() {
        showTerms = true
        showMainWindow()
    }
}

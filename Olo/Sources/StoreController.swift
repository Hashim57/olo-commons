import AppKit
import StoreKit
import OloKit

/// Subscriptions through StoreKit 2, as the Mac App Store requires (guideline 3.1.1):
/// the App Store takes the payment, helius-olo.io checks the transaction with Apple
/// and ties the plan to the account, and only then is the transaction finished.
/// Prices always come from StoreKit in the buyer's currency.
@MainActor
final class StoreController: ObservableObject {
    static let shared = StoreController()

    /// The two plans, in the order they are shown, once the App Store has answered.
    @Published private(set) var products: [Product] = []
    @Published private(set) var loadingProducts = false
    /// The product being bought right now, if any.
    @Published private(set) var purchasing: String?
    @Published private(set) var restoring = false
    /// A problem in plain words, or nil. A cancelled purchase leaves it nil.
    @Published var error: String?
    /// True after the server has confirmed a purchase in this session (the success state).
    @Published var purchased = false

    /// Sends a verified transaction to helius-olo.io; the fresh entitlement comes back.
    var redeem: (@MainActor (_ transactionId: String, _ productId: String) async throws -> Entitlement)?
    /// Called with every entitlement the server returns, so the app can show the plan.
    var onEntitlement: (@MainActor (Entitlement) -> Void)?

    private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            // Renewals, purchases finished on another device and Ask to Buy approvals arrive here.
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }
                await self.handle(result, announce: false)
            }
        }
    }

    deinit {
        updates?.cancel()
    }

    // MARK: Products

    func loadProducts() async {
        guard !loadingProducts else { return }
        loadingProducts = true
        defer { loadingProducts = false }
        do {
            let found = try await Product.products(for: OloProduct.ids)
            // Keep the order of OloProduct.all (Starter before Growth).
            products = OloProduct.ids.compactMap { id in found.first { $0.id == id } }
            if products.isEmpty { error = "The App Store did not return Olo's plans. Check your connection and try again." }
        } catch {
            self.error = "The App Store could not be reached: \(error.localizedDescription)"
        }
    }

    // MARK: Buying

    func purchase(_ product: Product) async {
        guard purchasing == nil else { return }
        purchasing = product.id
        error = nil
        defer { purchasing = nil }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(verification, announce: true)
            case .userCancelled:
                break
            case .pending:
                error = "The purchase is waiting for approval (for example Ask to Buy). Olo unlocks as soon as it goes through."
            @unknown default:
                break
            }
        } catch {
            let words = StoreController.plainWords(error)
            if !words.isEmpty { self.error = words }
        }
    }

    /// Asks the App Store for this Apple ID's purchases and tells the server about each one.
    func restore() async {
        guard !restoring else { return }
        restoring = true
        error = nil
        defer { restoring = false }
        do {
            try await AppStore.sync()
        } catch {
            if StoreController.isCancellation(error) { return }
            let words = StoreController.plainWords(error)
            if !words.isEmpty { self.error = words }
            return
        }
        var found = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard OloProduct.product(for: transaction.productID) != nil else { continue }
            found = true
            await redeemAndFinish(transaction, announce: true)
        }
        if !found && error == nil {
            error = "No Olo subscription was found for this Apple ID."
        }
    }

    /// Opens the App Store's subscription management page.
    func manageSubscriptions() {
        let candidates = ["macappstore://apps.apple.com/account/subscriptions", "https://apps.apple.com/account/subscriptions"]
        for c in candidates {
            if let url = URL(string: c), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: Transactions

    private func handle(_ result: VerificationResult<StoreKit.Transaction>, announce: Bool) async {
        switch result {
        case .verified(let transaction):
            await redeemAndFinish(transaction, announce: announce)
        case .unverified(_, let verificationError):
            if announce {
                error = "Apple could not verify this purchase (\(verificationError.localizedDescription)). Nothing is charged twice; try Restore Purchases in a moment."
            }
        }
    }

    /// The server confirms first; finish() only after it has, so a lost connection never loses a purchase.
    private func redeemAndFinish(_ transaction: StoreKit.Transaction, announce: Bool) async {
        guard OloProduct.product(for: transaction.productID) != nil else {
            // Not one of this app's plans (for example a test product): nothing to tell the server.
            await transaction.finish()
            return
        }
        if transaction.revocationDate != nil {
            // Refunded or revoked: the server learns from Apple's notifications; just clear it here.
            await transaction.finish()
            return
        }
        guard let redeem else {
            if announce { error = "Olo is not ready to record the purchase yet. Try Restore Purchases in a moment." }
            return
        }
        do {
            let entitlement = try await redeem(String(transaction.id), transaction.productID)
            await transaction.finish()
            onEntitlement?(entitlement)
            if announce {
                purchased = true
                error = nil
            }
        } catch {
            if announce {
                self.error = "The App Store took the payment but helius-olo.io could not record it yet (\(error.localizedDescription)). Press Restore Purchases, or reopen Olo later: the purchase is kept."
            }
        }
    }

    // MARK: Words

    static func isCancellation(_ error: Error) -> Bool {
        if let sk = error as? StoreKitError, case .userCancelled = sk { return true }
        return false
    }

    static func plainWords(_ error: Error) -> String {
        if let sk = error as? StoreKitError {
            switch sk {
            case .userCancelled: return ""
            case .networkError: return "The App Store could not be reached. Check your connection and try again."
            case .notAvailableInStorefront: return "This plan is not available in your country's App Store yet."
            case .notEntitled: return "This Apple ID is not allowed to make this purchase."
            default: return "The App Store had a problem. Try again in a moment."
            }
        }
        if let p = error as? Product.PurchaseError {
            switch p {
            case .purchaseNotAllowed: return "Purchases are not allowed on this Mac (check Screen Time or parental controls)."
            case .ineligibleForOffer: return "This offer is not available for your Apple ID."
            default: return "This plan is not available right now. Try again later."
            }
        }
        return error.localizedDescription
    }
}

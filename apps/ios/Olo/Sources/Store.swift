import OloKit
import StoreKit
import SwiftUI
import UIKit

/// Subscriptions through StoreKit 2, as the App Store requires (guideline 3.1.1), the same way
/// as the Mac app: the App Store takes the payment, helius-olo.io checks the transaction with
/// Apple and ties the plan to the account, and only then is the transaction finished. Prices
/// always come from StoreKit in the buyer's currency. The iPhone's products are OloProduct.phone.
@MainActor
final class StoreController: ObservableObject {
    /// The plans, in the order they are shown, once the App Store has answered.
    @Published private(set) var products: [Product] = []
    @Published private(set) var loadingProducts = false
    /// The product being bought right now, if any.
    @Published private(set) var purchasing: String?
    @Published private(set) var restoring = false
    /// A problem in plain words, or nil. A cancelled purchase leaves it nil.
    @Published var problem: String?
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
            let found = try await Product.products(for: OloProduct.phoneIds)
            // Keep the order of OloProduct.phone (Starter before Growth).
            products = OloProduct.phoneIds.compactMap { id in found.first { $0.id == id } }
            problem = products.isEmpty ? "The App Store did not return Olo's plans. Check your connection and try again." : nil
        } catch {
            problem = "The App Store could not be reached: \(error.localizedDescription)"
        }
    }

    // MARK: Buying

    func purchase(_ product: Product) async {
        guard purchasing == nil else { return }
        purchasing = product.id
        problem = nil
        defer { purchasing = nil }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(verification, announce: true)
            case .userCancelled:
                break
            case .pending:
                problem = "The purchase is waiting for approval (for example Ask to Buy). Olo unlocks as soon as it goes through."
            @unknown default:
                break
            }
        } catch {
            let words = StoreController.plainWords(error)
            if !words.isEmpty { problem = words }
        }
    }

    /// Asks the App Store for this Apple ID's purchases and tells the server about each one.
    func restore() async {
        guard !restoring else { return }
        restoring = true
        problem = nil
        defer { restoring = false }
        do {
            try await AppStore.sync()
        } catch {
            if StoreController.isCancellation(error) { return }
            let words = StoreController.plainWords(error)
            if !words.isEmpty { problem = words }
            return
        }
        var found = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard OloProduct.phoneProduct(for: transaction.productID) != nil else { continue }
            found = true
            await redeemAndFinish(transaction, announce: true)
        }
        if !found && problem == nil {
            problem = "No Olo subscription was found for this Apple ID."
        }
    }

    /// Opens the App Store's subscription management sheet, or its page when the sheet cannot be shown.
    func manageSubscriptions() async {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            do {
                try await AppStore.showManageSubscriptions(in: scene)
                return
            } catch {
                // Fall through to the web page.
            }
        }
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            _ = await UIApplication.shared.open(url)
        }
    }

    // MARK: Transactions

    private func handle(_ result: VerificationResult<StoreKit.Transaction>, announce: Bool) async {
        switch result {
        case .verified(let transaction):
            await redeemAndFinish(transaction, announce: announce)
        case .unverified(_, let verificationError):
            if announce {
                problem = "Apple could not verify this purchase (\(verificationError.localizedDescription)). Nothing is charged twice; try Restore Purchases in a moment."
            }
        }
    }

    /// The server confirms first; finish() only after it has, so a lost connection never loses a purchase.
    private func redeemAndFinish(_ transaction: StoreKit.Transaction, announce: Bool) async {
        guard OloProduct.phoneProduct(for: transaction.productID) != nil else {
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
            if announce { problem = "Olo is not ready to record the purchase yet. Try Restore Purchases in a moment." }
            return
        }
        do {
            let entitlement = try await redeem(String(transaction.id), transaction.productID)
            await transaction.finish()
            onEntitlement?(entitlement)
            if announce {
                purchased = true
                problem = nil
            }
        } catch {
            if announce {
                problem = "The App Store took the payment but helius-olo.io could not record it yet (\(error.localizedDescription)). Press Restore Purchases, or reopen Olo later: the purchase is kept."
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
            case .purchaseNotAllowed: return "Purchases are not allowed on this iPhone (check Screen Time or parental controls)."
            case .ineligibleForOffer: return "This offer is not available for your Apple ID."
            default: return "This plan is not available right now. Try again later."
            }
        }
        return error.localizedDescription
    }
}

/// The plans sheet: what each plan includes at the App Store's price, Restore Purchases, and the
/// renewal terms Apple requires beside the buy buttons.
struct PlansView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: StoreController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    OloFace(mood: store.purchased ? .happy : .idle, size: 84)
                    if store.purchased {
                        Text(BillingText.subscribedTitle).font(.title2.bold())
                        Text("You can keep going right here, and the same plan works on the web and on your Mac.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Continue") { store.purchased = false; dismiss() }.buttonStyle(.borderedProminent)
                    } else if !model.signedIn {
                        Text("Sign in first").font(.title2.bold())
                        Text("Your plan is tied to your Olo account, so it works on the web and your Mac as well as here. Sign in with your email; a code is all it takes.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Sign in") { dismiss(); model.showSignIn = true }.buttonStyle(.borderedProminent)
                    } else {
                        plans
                    }
                    if let problem = store.problem {
                        Text(problem).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    Text(Legal.renewalSentence).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Link("Terms", destination: Legal.termsURL)
                        Link("Privacy", destination: Legal.privacyURL)
                        Link("EULA", destination: Legal.eulaURL)
                    }
                    .font(.caption)
                    Button(store.restoring ? "Restoring" : "Restore Purchases") { Task { await store.restore() } }
                        .font(.footnote).disabled(store.restoring || !model.signedIn)
                }
                .padding(20)
            }
            .navigationTitle("Olo plans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { if store.products.isEmpty { await store.loadProducts() } }
        }
    }

    @ViewBuilder private var plans: some View {
        if let e = model.entitlement, e.subscribed {
            Text("You are on Olo \(e.planName): \(e.messagesRemaining) of \(e.messageLimit) messages left this month.")
                .font(.subheadline).multilineTextAlignment(.center)
            Button("Manage in the App Store") { Task { await store.manageSubscriptions() } }.font(.footnote)
        } else {
            Text(BillingText.freePlan).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        if store.loadingProducts { ProgressView() }
        ForEach(store.products, id: \.id) { product in
            planCard(product)
        }
        if store.products.isEmpty && !store.loadingProducts {
            Button("Try again") { Task { await store.loadProducts() } }
            Link("Manage your plan on helius-olo.io", destination: OloAPI.defaultBase).font(.footnote)
        }
    }

    private func planCard(_ product: Product) -> some View {
        let info = OloProduct.phoneProduct(for: product.id)
        let current = model.entitlement?.subscribed == true && model.entitlement?.tier == info?.tier
        return VStack(alignment: .leading, spacing: 6) {
            Text(info?.name ?? product.displayName).font(.headline)
            Text("\(product.displayPrice) a month").font(.title3.weight(.semibold))
            Text(info?.includes ?? product.description).font(.subheadline).foregroundStyle(.secondary)
            Button {
                Task { await store.purchase(product) }
            } label: {
                HStack {
                    if store.purchasing == product.id { ProgressView().controlSize(.small) }
                    Text(current ? "Current plan" : "Subscribe").frame(maxWidth: .infinity)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(current || store.purchasing != nil)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

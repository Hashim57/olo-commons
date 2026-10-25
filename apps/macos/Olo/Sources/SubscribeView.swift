import SwiftUI
import StoreKit
import OloKit

/// The subscription sheet: the two plans with prices from the App Store, what the free
/// plan gives, the renewal sentence Apple asks for, and the links. Sign-in comes first
/// when the person has no account yet, because the server ties the plan to the account.
struct SubscribeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: StoreController

    private var needsSignIn: Bool { model.user?.email == nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    if store.purchased {
                        success
                    } else if needsSignIn {
                        signInFirst
                    } else {
                        plans
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 540, idealHeight: 620)
        .onAppear {
            store.purchased = false
            store.error = nil
            Task { await store.loadProducts() }
        }
    }

    // MARK: Plans

    private var plans: some View {
        VStack(spacing: 16) {
            HeliusAtomView(mode: .idle, size: 120)
            Text("Olo plans").font(.title.weight(.semibold))
            if let e = model.entitlement, e.subscribed {
                VStack(spacing: 6) {
                    Text("You are on Olo \(e.planName): \(e.messagesRemaining.formatted()) of \(e.messageLimit.formatted()) messages left this month.")
                        .multilineTextAlignment(.center)
                    Button("Manage in the App Store") { store.manageSubscriptions() }
                }
            }
            Text(BillingText.freePlan).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if store.loadingProducts && store.products.isEmpty {
                ProgressView().controlSize(.small).padding(.vertical, 20)
            } else if store.products.isEmpty {
                Button("Try Again") { Task { await store.loadProducts() } }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(store.products) { product in planCard(product) }
                }
                .frame(maxWidth: 560)
            }
            if let err = store.error, !err.isEmpty {
                Text(err).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Text(Legal.renewalSentence)
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
        }
    }

    private func planCard(_ product: Product) -> some View {
        let info = OloProduct.product(for: product.id)
        let isCurrent = (model.entitlement?.subscribed ?? false) && model.entitlement?.tier == info?.tier
        let busy = store.purchasing == product.id
        return VStack(alignment: .leading, spacing: 8) {
            Text(info?.name ?? product.displayName).font(.headline)
            Text("\(product.displayPrice) a month").font(.title2.weight(.semibold))
            Text(info?.includes ?? product.description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button {
                Task { await store.purchase(product) }
            } label: {
                if busy {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Text(isCurrent ? "Current plan" : "Subscribe").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.purchasing != nil || isCurrent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Sign in first

    private var signInFirst: some View {
        VStack(spacing: 14) {
            HeliusAtomView(mode: .idle, size: 120)
            Text("Sign in first").font(.title.weight(.semibold))
            Text("Your plan is tied to your Olo account, so it works on the web and your iPhone as well as here. Sign in with your email; a six digit code is all it takes.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            SubscribeSignInForm()
                .frame(maxWidth: 420)
        }
    }

    // MARK: Success

    private var success: some View {
        VStack(spacing: 16) {
            HeliusAtomView(mode: .idle, size: 160)
            Text(BillingText.subscribedTitle).font(.title.weight(.semibold))
            Text(BillingText.subscribedBody)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            Button("Continue") {
                store.purchased = false
                dismiss()
                model.focusComposer += 1
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 20)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Link("Terms", destination: Legal.termsURL)
            Link("Privacy", destination: Legal.privacyURL)
            Link("EULA", destination: Legal.eulaURL)
            Spacer()
            if !store.purchased {
                if store.restoring { ProgressView().controlSize(.small) }
                Button("Restore Purchases") { Task { await store.restore() } }
                    .disabled(store.restoring || needsSignIn)
                    .help(needsSignIn ? "Sign in first, so the plan can be tied to your account" : "Find a plan bought with this Apple ID and attach it to your account")
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .font(.callout)
        .padding(14)
    }
}

/// Sign in inside the subscription sheet: the same email code as everywhere else, through
/// AppModel, without closing the sheet.
struct SubscribeSignInForm: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var code = ""
    @State private var sent = false
    @State private var busy = false
    @State private var error: String?
    @State private var consent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Email", text: $email).disabled(sent)
            if sent {
                TextField("Six digit code", text: $code)
                    .textContentType(.oneTimeCode)
                    .onChange(of: code) { code = String(code.filter(\.isNumber).prefix(6)) }
                Toggle(ConsentText.label, isOn: $consent)
                Text(ConsentText.paragraph).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if sent {
                    Button("Use a different email") { sent = false; code = "" }.buttonStyle(.borderless)
                    Button("Sign In") { Task { await verify() } }.keyboardShortcut(.defaultAction).disabled(code.count != 6 || busy)
                } else {
                    Button("Send Code") { Task { await send() } }.keyboardShortcut(.defaultAction).disabled(!email.contains("@") || busy)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func send() async {
        busy = true; error = nil
        defer { busy = false }
        do { try await model.requestCode(email: email.trimmingCharacters(in: .whitespaces)); sent = true }
        catch { self.error = error.localizedDescription }
    }

    private func verify() async {
        busy = true; error = nil
        defer { busy = false }
        do { try await model.verify(email: email.trimmingCharacters(in: .whitespaces), code: code, trainingConsent: consent) }
        catch { self.error = error.localizedDescription }
    }
}

/// The composer banner when the allowance is spent: one sentence and the way on.
struct QuotaBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.quotaBanner {
            HStack(spacing: 10) {
                Image(systemName: "hourglass")
                Text(text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if model.isSubscribed {
                    Button("Manage") { model.purchases.manageSubscriptions() }.controlSize(.small)
                } else {
                    Button("Subscribe") { model.openSubscribe() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .font(.callout)
            .padding(10)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Settings > Account: the plan and the terms, each with its button.
struct AccountPlanSection: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var store: StoreController

    var body: some View {
        Section("Plan") {
            HStack {
                Text(model.planLine)
                Spacer()
                if model.isSubscribed {
                    Button("Manage...") { store.manageSubscriptions() }
                        .help("Change or cancel the plan in the App Store")
                } else {
                    Button("Subscribe...") { model.openSubscribe() }
                }
            }
            if let e = model.entitlement {
                Text(e.subscribed
                     ? "\(e.messagesRemaining.formatted()) of \(e.messageLimit.formatted()) messages left this month. The same plan works on the web and your iPhone."
                     : "\(BillingText.freePlan) A plan bought on the web or the iPhone counts here too.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(BillingText.freePlan).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        Section("Terms") {
            HStack {
                if let a = model.termsAccepted {
                    Text("Terms accepted on \(a.acceptedAt.formatted(date: .long, time: .omitted))")
                } else {
                    Text("Terms not accepted yet")
                }
                Spacer()
                Button("Read again") { model.reopenTerms() }
            }
            HStack(spacing: 14) {
                Link("Terms of Use", destination: Legal.termsURL)
                Link("Apple's standard EULA", destination: Legal.eulaURL)
            }
            .font(.caption)
        }
    }
}

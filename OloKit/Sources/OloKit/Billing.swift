import Foundation

/// What this account may do right now, as helius-olo.io reports it
/// (billing.entitlement). The same answer serves the web, the iPhone and the Mac:
/// a plan bought in any of them counts everywhere.
public struct Entitlement: Codable, Equatable, Sendable {
    /// "free", "starter", "growth" or "enterprise".
    public var tier: String
    public var subscribed: Bool
    public var messagesUsed: Int
    public var messageLimit: Int
    public var messagesRemaining: Int
    public var computeUsed: Int
    public var computeLimit: Int
    public var computeRemaining: Int
    public var canSendMessage: Bool
    public var canRunCompute: Bool
    /// When the allowance refills, as the server writes dates (ISO 8601).
    public var refillsAt: String?
    /// Why sending is refused, when it is.
    public var blockedReason: String?

    public init(tier: String = "free", subscribed: Bool = false, messagesUsed: Int = 0, messageLimit: Int = 0, messagesRemaining: Int = 0,
                computeUsed: Int = 0, computeLimit: Int = 0, computeRemaining: Int = 0, canSendMessage: Bool = true, canRunCompute: Bool = true,
                refillsAt: String? = nil, blockedReason: String? = nil) {
        self.tier = tier; self.subscribed = subscribed
        self.messagesUsed = messagesUsed; self.messageLimit = messageLimit; self.messagesRemaining = messagesRemaining
        self.computeUsed = computeUsed; self.computeLimit = computeLimit; self.computeRemaining = computeRemaining
        self.canSendMessage = canSendMessage; self.canRunCompute = canRunCompute
        self.refillsAt = refillsAt; self.blockedReason = blockedReason
    }

    enum CodingKeys: String, CodingKey {
        case tier, subscribed, messagesUsed, messageLimit, messagesRemaining, computeUsed, computeLimit, computeRemaining
        case canSendMessage, canRunCompute, refillsAt, blockedReason
    }

    /// Reads what the server sends, filling anything missing with safe defaults, so a
    /// field added or dropped on the server never breaks the Mac.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier = (try? c.decodeIfPresent(String.self, forKey: .tier)) ?? "free"
        subscribed = (try? c.decodeIfPresent(Bool.self, forKey: .subscribed)) ?? (tier != "free")
        messagesUsed = (try? c.decodeIfPresent(Int.self, forKey: .messagesUsed)) ?? 0
        messageLimit = (try? c.decodeIfPresent(Int.self, forKey: .messageLimit)) ?? 0
        messagesRemaining = (try? c.decodeIfPresent(Int.self, forKey: .messagesRemaining)) ?? max(0, messageLimit - messagesUsed)
        computeUsed = (try? c.decodeIfPresent(Int.self, forKey: .computeUsed)) ?? 0
        computeLimit = (try? c.decodeIfPresent(Int.self, forKey: .computeLimit)) ?? 0
        computeRemaining = (try? c.decodeIfPresent(Int.self, forKey: .computeRemaining)) ?? max(0, computeLimit - computeUsed)
        canSendMessage = (try? c.decodeIfPresent(Bool.self, forKey: .canSendMessage)) ?? true
        canRunCompute = (try? c.decodeIfPresent(Bool.self, forKey: .canRunCompute)) ?? true
        refillsAt = try? c.decodeIfPresent(String.self, forKey: .refillsAt)
        blockedReason = try? c.decodeIfPresent(String.self, forKey: .blockedReason)
    }

    /// "Free", "Starter", "Growth", "Enterprise".
    public var planName: String {
        switch tier {
        case "starter": return "Starter"
        case "growth": return "Growth"
        case "enterprise": return "Enterprise"
        default: return "Free"
        }
    }

    public var isFree: Bool { tier == "free" || !subscribed }

    public var refillsAtDate: Date? { refillsAt.flatMap(ISO8601.parse) }

    /// The free allowance is spent and the person is not on a plan: the moment to offer one.
    public var needsPlanToContinue: Bool { !canSendMessage && isFree }
}

/// The Mac app's subscriptions as App Store Connect knows them. Prices are never
/// written here: StoreKit supplies them in the buyer's currency.
public struct OloProduct: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let tier: String
    public let messagesPerMonth: Int
    public let analysesPerMonth: Int

    public static let starterMonthly = OloProduct(id: "com.helius.olo.desktop.starter.monthly", name: "Olo Starter", tier: "starter", messagesPerMonth: 500, analysesPerMonth: 10)
    public static let growthMonthly = OloProduct(id: "com.helius.olo.desktop.growth.monthly", name: "Olo Growth", tier: "growth", messagesPerMonth: 5_000, analysesPerMonth: 100)

    /// In the order they are shown.
    public static let all: [OloProduct] = [starterMonthly, growthMonthly]
    public static var ids: [String] { all.map(\.id) }

    public static func product(for id: String) -> OloProduct? { all.first { $0.id == id } }

    /// "500 messages a month, 10 analyses".
    public var includes: String {
        "\(OloProduct.grouped(messagesPerMonth)) messages a month, \(OloProduct.grouped(analysesPerMonth)) analyses"
    }

    /// 5000 as "5,000", the same in every locale so the words match the listing.
    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
}

/// Words the billing screens share.
public enum BillingText {
    public static let freePlan = "The free plan includes 5 messages a day, refilled every 24 hours."
    public static let subscribedTitle = "You're subscribed."
    public static let subscribedBody = "You can keep chatting with Olo right here on your Mac, and the same plan works on the web and on your iPhone."

    /// The composer banner when the free messages are gone, naming when they come back.
    public static func freeMessagesSpent(refillsAt: Date?, now: Date = Date(), calendar: Calendar = .current, timeZone: TimeZone = .current) -> String {
        let lead = "You have used today's free messages. Subscribe to keep going"
        guard let refillsAt, refillsAt > now else { return lead + "." }
        var cal = calendar
        cal.timeZone = timeZone
        let time = DateFormatter()
        time.calendar = cal
        time.timeZone = timeZone
        time.locale = Locale(identifier: "en_GB")
        time.dateFormat = "HH:mm"
        let clock = time.string(from: refillsAt)
        if cal.isDate(refillsAt, inSameDayAs: now) { return lead + ", or come back at \(clock)." }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(refillsAt, inSameDayAs: tomorrow) {
            return lead + ", or come back tomorrow at \(clock)."
        }
        time.dateFormat = "d MMMM 'at' HH:mm"
        return lead + ", or come back on \(time.string(from: refillsAt))."
    }

    /// The composer banner when a plan's monthly allowance is gone.
    public static func planMessagesSpent(plan: String, refillsAt: Date?, calendar: Calendar = .current, timeZone: TimeZone = .current) -> String {
        guard let refillsAt else { return "You have used this month's messages on Olo \(plan)." }
        var cal = calendar
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMMM"
        return "You have used this month's messages on Olo \(plan). They refill on \(f.string(from: refillsAt))."
    }
}

// MARK: Server calls

extension OloAPI {
    /// What this account may do now (billing.entitlement, signed in).
    public func fetchEntitlement() async throws -> Entitlement {
        try await run(try TRPC.queryRequest(base: base, path: "billing.entitlement", token: token), as: Entitlement.self)
    }

    public struct ApplePurchasesAvailable: Codable, Sendable {
        public var available: Bool
        public init(available: Bool) { self.available = available }
    }

    /// Whether the server verifies App Store purchases yet (billing.applePurchasesAvailable, public).
    public func applePurchasesAvailable() async throws -> Bool {
        let r = try await run(try TRPC.queryRequest(base: base, path: "billing.applePurchasesAvailable", token: token), as: ApplePurchasesAvailable.self)
        return r.available
    }

    public struct RedeemInput: Codable, Sendable {
        public let transactionId: String
        public let productId: String
        public init(transactionId: String, productId: String) { self.transactionId = transactionId; self.productId = productId }
    }

    /// Tells the server about a verified App Store transaction; it checks the receipt with
    /// Apple and ties the plan to the account. The fresh entitlement comes back.
    public func redeemApplePurchase(transactionId: String, productId: String) async throws -> Entitlement {
        let req = try TRPC.mutationRequest(base: base, path: "billing.redeemApplePurchase",
                                           input: RedeemInput(transactionId: transactionId, productId: productId), token: token)
        return try await run(req, as: Entitlement.self)
    }
}

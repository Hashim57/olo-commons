import XCTest
@testable import OloKit

final class LegalTests: XCTestCase {
    private func freshStore() -> LegalStore {
        let suite = "io.helius-olo.tests.legal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return LegalStore(defaults: defaults)
    }

    func testNothingAcceptedAtFirst() {
        let s = freshStore()
        XCTAssertNil(s.acceptance)
        XCTAssertFalse(s.accepted())
        XCTAssertFalse(s.acceptedOlderVersion())
    }

    func testRecordThenAccepted() {
        let s = freshStore()
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let a = s.record(at: when)
        XCTAssertEqual(a.version, Legal.termsVersion)
        XCTAssertTrue(s.accepted())
        XCTAssertEqual(s.acceptance?.version, Legal.termsVersion)
        XCTAssertEqual(s.acceptance?.acceptedAt.timeIntervalSince1970 ?? 0, when.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(s.acceptedOlderVersion())
    }

    func testNewVersionAsksAgain() {
        let s = freshStore()
        s.record(version: "2025-01-01")
        XCTAssertFalse(s.accepted(for: Legal.termsVersion))
        XCTAssertTrue(s.acceptedOlderVersion(than: Legal.termsVersion))
        s.record(version: Legal.termsVersion)
        XCTAssertTrue(s.accepted(for: Legal.termsVersion))
        XCTAssertFalse(s.acceptedOlderVersion(than: Legal.termsVersion))
    }

    func testResetForgets() {
        let s = freshStore()
        s.record()
        s.reset()
        XCTAssertNil(s.acceptance)
        XCTAssertFalse(s.accepted())
    }

    func testSummaryCoversWhatTheTermsPromise() {
        let all = Legal.summary.map { $0.title + " " + $0.text }.joined(separator: " ")
        for needle in ["Helius Network Ltd", "England and Wales", "can be wrong", "email", "24 hours", "App Store", "stays yours", "consent", "Flags"] {
            XCTAssertTrue(all.contains(needle), "summary should mention \(needle)")
        }
        XCTAssertEqual(Legal.termsURL.host, "helius-olo.io")
        XCTAssertEqual(Legal.privacyURL.host, "helius-olo.io")
        XCTAssertTrue(Legal.eulaURL.absoluteString.hasSuffix("/stdeula/"))
        XCTAssertEqual(Legal.termsVersion.count, 10)
    }

    func testNoDashesInUserFacingText() {
        let everything = Legal.summary.map { $0.title + $0.text }.joined() + Legal.renewalSentence + BillingText.freePlan + BillingText.subscribedBody
        XCTAssertFalse(everything.contains("\u{2014}"))
        XCTAssertFalse(everything.contains("\u{2013}"))
    }
}

final class BillingTests: XCTestCase {
    func testEntitlementDecodesTheServerShape() throws {
        let json = #"{"tier":"starter","subscribed":true,"messagesUsed":12,"messageLimit":500,"messagesRemaining":488,"computeUsed":1,"computeLimit":10,"computeRemaining":9,"canSendMessage":true,"canRunCompute":true,"refillsAt":"2026-11-01T00:00:00.000Z","blockedReason":null}"#
        let e = try JSONDecoder().decode(Entitlement.self, from: Data(json.utf8))
        XCTAssertEqual(e.tier, "starter")
        XCTAssertTrue(e.subscribed)
        XCTAssertEqual(e.messagesRemaining, 488)
        XCTAssertEqual(e.planName, "Starter")
        XCTAssertFalse(e.isFree)
        XCTAssertFalse(e.needsPlanToContinue)
        XCTAssertNotNil(e.refillsAtDate)
        XCTAssertNil(e.blockedReason)
    }

    func testEntitlementSurvivesMissingFields() throws {
        let e = try JSONDecoder().decode(Entitlement.self, from: Data(#"{"tier":"free","canSendMessage":false,"blockedReason":"daily_limit"}"#.utf8))
        XCTAssertEqual(e.planName, "Free")
        XCTAssertTrue(e.isFree)
        XCTAssertFalse(e.canSendMessage)
        XCTAssertTrue(e.needsPlanToContinue)
        XCTAssertEqual(e.blockedReason, "daily_limit")
        XCTAssertEqual(e.messagesRemaining, 0)
        XCTAssertNil(e.refillsAtDate)
    }

    func testEntitlementInsideTRPCEnvelope() throws {
        let body = #"{"result":{"data":{"json":{"tier":"growth","subscribed":true,"canSendMessage":true}}}}"#
        let e = try TRPC.decode(Entitlement.self, data: Data(body.utf8), status: 200)
        XCTAssertEqual(e.planName, "Growth")
        XCTAssertTrue(e.subscribed)
    }

    func testSubscribedOnThePlanButOutOfMessagesIsNotAskedToBuyAgain() {
        let e = Entitlement(tier: "growth", subscribed: true, canSendMessage: false, blockedReason: "monthly_limit")
        XCTAssertFalse(e.needsPlanToContinue)
    }

    func testProductsMatchAppStoreConnect() {
        XCTAssertEqual(OloProduct.ids, ["com.helius.olo.desktop.starter.monthly", "com.helius.olo.desktop.growth.monthly"])
        XCTAssertEqual(OloProduct.product(for: "com.helius.olo.desktop.growth.monthly")?.name, "Olo Growth")
        XCTAssertEqual(OloProduct.starterMonthly.includes, "500 messages a month, 10 analyses")
        XCTAssertEqual(OloProduct.growthMonthly.includes, "5,000 messages a month, 100 analyses")
        XCTAssertEqual(OloProduct.starterMonthly.tier, "starter")
        XCTAssertNil(OloProduct.product(for: "com.helius.olo.iphone.starter.monthly"))
    }

    func testRedeemInputEncodesBothFields() throws {
        let data = try JSONEncoder().encode(OloAPI.RedeemInput(transactionId: "2000000123456789", productId: OloProduct.starterMonthly.id))
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(v["transactionId"]?.stringValue, "2000000123456789")
        XCTAssertEqual(v["productId"]?.stringValue, "com.helius.olo.desktop.starter.monthly")
    }

    func testBillingRequestsUseTheRightProcedures() throws {
        let base = URL(string: "https://helius-olo.io")!
        let q = try TRPC.queryRequest(base: base, path: "billing.entitlement", token: "tok")
        XCTAssertEqual(q.httpMethod, "GET")
        XCTAssertTrue(q.url!.path.hasSuffix("/api/trpc/billing.entitlement"))
        XCTAssertEqual(q.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let m = try TRPC.mutationRequest(base: base, path: "billing.redeemApplePurchase", input: OloAPI.RedeemInput(transactionId: "1", productId: "p"), token: "tok")
        XCTAssertEqual(m.httpMethod, "POST")
        XCTAssertTrue(m.url!.path.hasSuffix("/api/trpc/billing.redeemApplePurchase"))
        let sent = try JSONDecoder().decode(JSONValue.self, from: m.httpBody!)
        XCTAssertEqual(sent["json"]?["transactionId"]?.stringValue, "1")
    }

    func testFreeMessagesBannerNamesTheRefillTime() {
        let tz = TimeZone(identifier: "Europe/London")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9, minute: 0))!
        let later = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 17, minute: 30))!
        XCTAssertEqual(BillingText.freeMessagesSpent(refillsAt: later, now: now, calendar: cal, timeZone: tz),
                       "You have used today's free messages. Subscribe to keep going, or come back at 17:30.")
        let tomorrow = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 8, minute: 5))!
        XCTAssertEqual(BillingText.freeMessagesSpent(refillsAt: tomorrow, now: now, calendar: cal, timeZone: tz),
                       "You have used today's free messages. Subscribe to keep going, or come back tomorrow at 08:05.")
        XCTAssertEqual(BillingText.freeMessagesSpent(refillsAt: nil, now: now, calendar: cal, timeZone: tz),
                       "You have used today's free messages. Subscribe to keep going.")
        let past = cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 8, minute: 0))!
        XCTAssertEqual(BillingText.freeMessagesSpent(refillsAt: past, now: now, calendar: cal, timeZone: tz),
                       "You have used today's free messages. Subscribe to keep going.")
    }

    func testPlanBannerNamesTheMonth() {
        let tz = TimeZone(identifier: "Europe/London")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let first = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 0))!
        XCTAssertEqual(BillingText.planMessagesSpent(plan: "Starter", refillsAt: first, calendar: cal, timeZone: tz),
                       "You have used this month's messages on Olo Starter. They refill on 1 November.")
        XCTAssertEqual(BillingText.planMessagesSpent(plan: "Growth", refillsAt: nil), "You have used this month's messages on Olo Growth.")
    }

    func testRenewalSentenceIsTheOneAppleAsksFor() {
        XCTAssertTrue(Legal.renewalSentence.contains("24 hours before the end of the current period"))
        XCTAssertTrue(Legal.renewalSentence.contains("App Store settings"))
        XCTAssertTrue(BillingText.freePlan.contains("5 messages a day"))
    }
}

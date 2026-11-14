import Foundation

/// The iPhone app's subscriptions as App Store Connect knows them. They are separate products from
/// the Mac's (a product belongs to one app), mapped to the same plans by helius-olo.io
/// (server/applePurchases.ts), so a plan bought on the phone counts on the web and the Mac too.
/// Prices are never written here: StoreKit supplies them in the buyer's currency.
extension OloProduct {
    public static let phoneStarterMonthly = OloProduct(id: "com.helius.olo.starter.monthly", name: "Olo Starter", tier: "starter", messagesPerMonth: 500, analysesPerMonth: 10)
    public static let phoneGrowthMonthly = OloProduct(id: "com.helius.olo.growth.monthly", name: "Olo Growth", tier: "growth", messagesPerMonth: 5_000, analysesPerMonth: 100)

    /// In the order they are shown.
    public static let phone: [OloProduct] = [phoneStarterMonthly, phoneGrowthMonthly]
    public static var phoneIds: [String] { phone.map(\.id) }

    public static func phoneProduct(for id: String) -> OloProduct? { phone.first { $0.id == id } }
}

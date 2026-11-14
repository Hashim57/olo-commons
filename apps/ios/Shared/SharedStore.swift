import Foundation

/// The little the Home Screen widget needs, written by the app and read by the widget through the
/// app group. Only the next event's title and time and one line from Olo. No message text.
struct OloSnapshot: Codable, Equatable {
    var line: String
    var nextTitle: String?
    var nextStart: Date?
    var updated: Date
}

enum SharedStore {
    static let group = "group.com.helius.olo"
    static let key = "olo.snapshot.v1"
    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    static func write(_ s: OloSnapshot) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
    }
    static func read() -> OloSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(OloSnapshot.self, from: data)
    }
}

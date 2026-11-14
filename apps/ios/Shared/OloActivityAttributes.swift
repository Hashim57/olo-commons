import ActivityKit
import Foundation

/// What Olo shows in the Dynamic Island and on the Lock Screen while it keeps you company:
/// its mood, one line, and (when there is one) the next thing in your day with its start time.
struct OloActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var mood: OloMood
        var line: String
        var nextTitle: String?
        var nextStart: Date?
    }
    var name: String
}

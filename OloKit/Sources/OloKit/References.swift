import Foundation

/// One DOI or quoted paper title from an answer, looked up in Crossref by the server
/// (server/references.ts). Sent as the "references" stream event and saved inside
/// the verification.
public struct ReferenceCheck: Codable, Equatable, Sendable {
    public var text: String
    public var doi: String?
    /// True when Crossref knows the work; false when it does not; nil when not checked or the lookup failed.
    public var exists: Bool?
    public var title: String?
    /// "retracted", "no match in Crossref", "lookup failed", "not checked" or nil.
    public var note: String?

    public init(text: String, doi: String? = nil, exists: Bool? = nil, title: String? = nil, note: String? = nil) {
        self.text = text; self.doi = doi; self.exists = exists; self.title = title; self.note = note
    }

    enum CodingKeys: String, CodingKey { case text, doi, exists, title, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        doi = try? c.decodeIfPresent(String.self, forKey: .doi)
        exists = try? c.decodeIfPresent(Bool.self, forKey: .exists)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
    }

    /// True when a reference was found but Crossref records a retraction against it.
    public var isRetracted: Bool { note == "retracted" }
}

/// The line under an answer about its references. Mirrors client/src/lib/references.ts
/// word for word, so the Mac never disagrees with the web.
public enum References {
    /// "N references checked, M not found" (and ", K retracted" when any were), or nil when nothing was checked.
    public static func line(_ references: [ReferenceCheck]?) -> String? {
        guard let references else { return nil }
        let checked = references.filter { $0.exists != nil }
        if checked.isEmpty { return nil }
        let missing = checked.filter { $0.exists == false }.count
        let retracted = checked.filter { $0.isRetracted }.count
        var parts = ["\(checked.count) \(checked.count == 1 ? "reference" : "references") checked", "\(missing) not found"]
        if retracted > 0 { parts.append("\(retracted) retracted") }
        return parts.joined(separator: ", ")
    }

    /// The references to list under the line: those not found, and those retracted.
    public static func flagged(_ references: [ReferenceCheck]?) -> [ReferenceCheck] {
        guard let references else { return [] }
        return references.filter { $0.exists == false || $0.isRetracted }
    }
}

/// What Olo remembered about the person that shaped a reply ("memories" stream event).
public struct UsedMemory: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var category: String
    public var content: String

    public init(id: String, category: String, content: String) {
        self.id = id; self.category = category; self.content = content
    }
}

import Foundation
import NaturalLanguage

/// The language of a voice conversation, mirroring voiceLanguage.ts in olo-web
/// and the iPhone app. A speech recogniser has to be told which language to
/// listen for (none detects it), so the person picks one or leaves it on
/// Automatic, which follows the Mac's language. Olo's own voice speaks whatever
/// language the answer is in; the Mac's fallback voice is told the answer's
/// language, found with NLLanguageRecognizer, so a German answer is not read with
/// English sounds.
public enum VoiceLanguage {
    public static let auto = "auto"
    public static let preferenceKey = "voiceLanguage"

    public struct Option: Identifiable, Equatable, Sendable {
        public let code: String
        public let label: String
        public var id: String { code }
        public init(code: String, label: String) { self.code = code; self.label = label }
    }

    /// Languages offered in the picker: the ones the Apple recogniser carries on every Mac.
    public static let options: [Option] = [
        Option(code: "en-GB", label: "English (UK)"), Option(code: "en-US", label: "English (US)"), Option(code: "en-IN", label: "English (India)"),
        Option(code: "de-DE", label: "Deutsch"), Option(code: "fr-FR", label: "Français"), Option(code: "es-ES", label: "Español (España)"),
        Option(code: "es-MX", label: "Español (México)"), Option(code: "it-IT", label: "Italiano"), Option(code: "pt-PT", label: "Português (Portugal)"),
        Option(code: "pt-BR", label: "Português (Brasil)"), Option(code: "nl-NL", label: "Nederlands"), Option(code: "sv-SE", label: "Svenska"),
        Option(code: "da-DK", label: "Dansk"), Option(code: "nb-NO", label: "Norsk"), Option(code: "fi-FI", label: "Suomi"), Option(code: "pl-PL", label: "Polski"),
        Option(code: "cs-CZ", label: "Čeština"), Option(code: "ro-RO", label: "Română"), Option(code: "hu-HU", label: "Magyar"), Option(code: "el-GR", label: "Ελληνικά"),
        Option(code: "tr-TR", label: "Türkçe"), Option(code: "ru-RU", label: "Русский"), Option(code: "uk-UA", label: "Українська"), Option(code: "ar-SA", label: "العربية"),
        Option(code: "he-IL", label: "עברית"), Option(code: "fa-IR", label: "فارسی"), Option(code: "ur-PK", label: "اردو"), Option(code: "hi-IN", label: "हिन्दी"),
        Option(code: "bn-IN", label: "বাংলা"), Option(code: "ta-IN", label: "தமிழ்"), Option(code: "th-TH", label: "ไทย"), Option(code: "vi-VN", label: "Tiếng Việt"),
        Option(code: "id-ID", label: "Bahasa Indonesia"), Option(code: "ms-MY", label: "Bahasa Melayu"), Option(code: "zh-CN", label: "中文 (简体)"),
        Option(code: "zh-TW", label: "中文 (繁體)"), Option(code: "yue-HK", label: "粵語"), Option(code: "ja-JP", label: "日本語"), Option(code: "ko-KR", label: "한국어"),
        Option(code: "sw-KE", label: "Kiswahili"),
    ]

    /// A locale identifier ("de", "de_AT", "en-GB", "zh-Hans-CN") as the BCP-47 tag a recogniser accepts.
    public static func normalise(_ locale: String?) -> String {
        let raw = (locale ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
        if raw.isEmpty { return "en-GB" }
        let parts = raw.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        guard let first = parts.first else { return "en-GB" }
        let lang = first.lowercased()
        let region = parts.dropFirst().first { $0.count == 2 && $0.allSatisfy(\.isLetter) }?.uppercased()
        let script = parts.dropFirst().first { $0.count == 4 && $0.allSatisfy(\.isLetter) }?.lowercased()
        if lang == "zh" {
            if script == "hant" || region == "TW" || region == "HK" || region == "MO" { return region == "HK" ? "zh-HK" : "zh-TW" }
            return "zh-CN"
        }
        if let region { return "\(lang)-\(region)" }
        if let known = options.first(where: { $0.code.lowercased().hasPrefix("\(lang)-") }) { return known.code }
        return lang
    }

    /// The language to listen for: the person's choice, or the Mac's language when on Automatic.
    public static func resolve(preference: String?, deviceLocale: String?) -> String {
        if let preference, preference != auto { return normalise(preference) }
        return normalise(deviceLocale)
    }

    /// The label shown for a code, or the code itself for one not in the list.
    public static func label(_ code: String) -> String {
        if let exact = options.first(where: { $0.code == code }) { return exact.label }
        let base = code.split(separator: "-").first.map(String.init) ?? code
        if let near = options.first(where: { $0.code.split(separator: "-").first.map(String.init) == base }) { return "\(near.label) (\(code))" }
        return code
    }

    /// The person's choice from UserDefaults ("auto" when unset).
    public static func preference(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: preferenceKey) ?? auto
    }

    /// The locale to recognise with right now.
    public static func listeningLocale(_ defaults: UserDefaults = .standard) -> Locale {
        Locale(identifier: resolve(preference: preference(defaults), deviceLocale: Locale.current.identifier))
    }

    /// The language a text is written in, as a BCP-47 tag ("de-DE", "ja-JP"), or nil when the recogniser
    /// cannot tell (a few words, numbers, code). Regions are taken from the picker list for the base
    /// language, so a voice can be picked for it.
    public static func languageOf(_ text: String) -> String? {
        let sample = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        let letters = sample.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 12 else { return nil }
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(String(sample.prefix(4000)))
        guard let language = recogniser.dominantLanguage, language != .undetermined else { return nil }
        let hypotheses = recogniser.languageHypotheses(withMaximum: 2)
        guard (hypotheses[language] ?? 0) >= 0.5 else { return nil }
        let base = language.rawValue.lowercased()
        if base.hasPrefix("zh") { return base.contains("hant") ? "zh-TW" : "zh-CN" }
        if let known = options.first(where: { $0.code.lowercased().hasPrefix("\(base)-") }) { return known.code }
        return base
    }

    /// Whether two tags are the same language (en-GB and en-US are).
    public static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.split(separator: "-").first?.lowercased() == b.split(separator: "-").first?.lowercased()
    }
}

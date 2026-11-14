import XCTest
@testable import OloKit

final class VoiceLanguageTests: XCTestCase {
    func testNormalisesLocales() {
        XCTAssertEqual(VoiceLanguage.normalise("de"), "de-DE")
        XCTAssertEqual(VoiceLanguage.normalise("de_AT"), "de-AT")
        XCTAssertEqual(VoiceLanguage.normalise("en-GB"), "en-GB")
        XCTAssertEqual(VoiceLanguage.normalise("zh-Hans-CN"), "zh-CN")
        XCTAssertEqual(VoiceLanguage.normalise("zh_Hant_TW"), "zh-TW")
        XCTAssertEqual(VoiceLanguage.normalise("zh_HK"), "zh-HK")
        XCTAssertEqual(VoiceLanguage.normalise(""), "en-GB")
        XCTAssertEqual(VoiceLanguage.normalise(nil), "en-GB")
    }

    func testResolveFollowsTheChoiceThenTheMac() {
        XCTAssertEqual(VoiceLanguage.resolve(preference: VoiceLanguage.auto, deviceLocale: "fr-FR"), "fr-FR")
        XCTAssertEqual(VoiceLanguage.resolve(preference: nil, deviceLocale: "es"), "es-ES")
        XCTAssertEqual(VoiceLanguage.resolve(preference: "ja-JP", deviceLocale: "en-GB"), "ja-JP")
        XCTAssertEqual(VoiceLanguage.resolve(preference: "ar_SA", deviceLocale: "en-GB"), "ar-SA")
    }

    func testLabels() {
        for option in VoiceLanguage.options { XCTAssertEqual(VoiceLanguage.label(option.code), option.label) }
        XCTAssertEqual(VoiceLanguage.label("en-AU"), "English (UK) (en-AU)")
        XCTAssertTrue(VoiceLanguage.same("en-GB", "en-US"))
        XCTAssertFalse(VoiceLanguage.same("de-DE", "nl-NL"))
        XCTAssertFalse(VoiceLanguage.same(nil, "de-DE"))
    }

    func testLanguageOfText() {
        XCTAssertEqual(VoiceLanguage.languageOf("Die Temperatur in Berlin ist heute zwölf Grad und es wird nicht regnen, auch nicht am Abend."), "de-DE")
        XCTAssertEqual(VoiceLanguage.languageOf("La température à Paris est de quinze degrés et il ne va pas pleuvoir dans la soirée."), "fr-FR")
        XCTAssertEqual(VoiceLanguage.languageOf("The temperature in London is twelve degrees today and it is not going to rain this evening."), "en-GB")
        XCTAssertEqual(VoiceLanguage.languageOf("هذا هو الجواب الكامل على سؤالك عن الطقس اليوم في لندن"), "ar-SA")
        XCTAssertEqual(VoiceLanguage.languageOf("今日の天気は晴れです。気温は二十度です。"), "ja-JP")
        XCTAssertNil(VoiceLanguage.languageOf("12.4"))
        XCTAssertNil(VoiceLanguage.languageOf(""))
        XCTAssertNil(VoiceLanguage.languageOf("```js\nconst x = 1;\n```"))
    }
}

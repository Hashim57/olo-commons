import XCTest
@testable import OloKit

/// What the iPhone app adds to OloKit: its App Store products, email drafts read out of an
/// answer, and Word documents written without AppKit.
final class PhoneTests: XCTestCase {
    func testPhoneProductsAreTheOnesTheServerKnows() {
        XCTAssertEqual(OloProduct.phoneIds, ["com.helius.olo.starter.monthly", "com.helius.olo.growth.monthly"])
        XCTAssertEqual(OloProduct.phoneProduct(for: "com.helius.olo.growth.monthly")?.tier, "growth")
        XCTAssertNil(OloProduct.phoneProduct(for: "com.helius.olo.desktop.growth.monthly"))
        // The Mac's list is unchanged.
        XCTAssertNil(OloProduct.product(for: "com.helius.olo.starter.monthly"))
        XCTAssertEqual(OloProduct.phoneStarterMonthly.includes, "500 messages a month, 10 analyses")
    }

    func testMailDraftWithSubject() {
        let answer = "Here is a draft:\n\n**To:** Sam Lee <sam@example.org>\n**Subject:** Rent review on 3 March\n\nDear Sam,\n\nCould we **move** the review?\n\nThanks,\nAlex"
        let d = MailDraft.parse(answer)
        XCTAssertEqual(d.to, ["sam@example.org"])
        XCTAssertEqual(d.subject, "Rent review on 3 March")
        XCTAssertEqual(d.body, "Dear Sam,\n\nCould we move the review?\n\nThanks,\nAlex")
    }

    func testMailDraftWithoutSubjectKeepsEverything() {
        let d = MailDraft.parse("Hi Sam,\nSee you at 4.\n")
        XCTAssertEqual(d.subject, "")
        XCTAssertEqual(d.to, [])
        XCTAssertEqual(d.body, "Hi Sam,\nSee you at 4.")
    }

    func testMailDraftInsideACodeFence() {
        let d = MailDraft.parse("```\nSubject: Hello\nBody line\n```")
        XCTAssertEqual(d.subject, "Hello")
        XCTAssertEqual(d.body, "Body line")
    }

    func testMailtoKeepsPlusSigns() {
        let url = MailDraft(to: ["a@example.org"], subject: "1+1", body: "two & more").mailtoURL
        let s = url?.absoluteString ?? ""
        XCTAssertTrue(s.hasPrefix("mailto:a@example.org?"))
        XCTAssertTrue(s.contains("subject=1%2B1"))
        XCTAssertFalse(s.contains(" "))
    }

    func testMarkdownParagraphs() {
        let p = DocumentText.paragraphs(markdown: "# Plan\nSome **bold** text\n- one\n* two\n```\nlet x = 1\n```\n| A | B |\n|---|---|\n| 1 | 2 |", title: "Doc")
        XCTAssertEqual(p.map(\.kind), [.title, .heading(1), .body, .bullet, .bullet, .code, .tableRow, .tableRow])
        XCTAssertEqual(p[2].runs, [DocRun("Some "), DocRun("bold", bold: true), DocRun(" text")])
        XCTAssertEqual(p[5].text, "let x = 1")
        XCTAssertEqual(p[6].text, "A\tB")
        XCTAssertEqual(p[7].text, "1\t2")
        XCTAssertTrue(p[1].runs.allSatisfy(\.bold))
    }

    func testConversationParagraphs() {
        let c = LocalConversation(title: "Tenancy", turns: [Turn(role: .user, text: "What should I check?"), Turn(role: .assistant, text: "Check the **deposit**.")])
        let p = DocumentText.paragraphs(conversation: c)
        XCTAssertEqual(p.first?.text, "Tenancy")
        XCTAssertEqual(p[1].text, TranscriptExport.header)
        XCTAssertTrue(p.contains { $0.text == "Check the deposit." })
        XCTAssertEqual(p.filter { $0.kind == .heading(3) }.count, 2)
    }

    func testCRC32() {
        XCTAssertEqual(StoredZip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(StoredZip.crc32(Data()), 0)
    }

    func testZipLayout() {
        let payload = Data("hello".utf8)
        let zip = StoredZip.archive([("a.txt", payload)])
        let bytes = [UInt8](zip)
        // Local header, then the name and the bytes as they are.
        XCTAssertEqual(Array(bytes[0..<4]), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(Array(bytes[30..<35]), Array("a.txt".utf8))
        XCTAssertEqual(Array(bytes[35..<40]), Array("hello".utf8))
        // The central directory starts where the end record says, and the end record closes the file.
        let end = bytes.count - 22
        XCTAssertEqual(Array(bytes[end..<end + 4]), [0x50, 0x4B, 0x05, 0x06])
        let start = Int(bytes[end + 16]) | Int(bytes[end + 17]) << 8
        XCTAssertEqual(start, 40)
        XCTAssertEqual(Array(bytes[start..<start + 4]), [0x50, 0x4B, 0x01, 0x02])
        XCTAssertEqual(Int(bytes[end + 10]), 1)
        // 30 header + 5 name + 5 data, 46 + 5 central, 22 end.
        XCTAssertEqual(bytes.count, 40 + 51 + 22)
    }

    func testDocxParts() {
        let xml = DocxWriter.documentXML([DocParagraph(.body, [DocRun("a < b & c\u{0001}"), DocRun("x\ty", bold: true)]), DocParagraph(.bullet, text: "item")])
        XCTAssertTrue(xml.contains("a &lt; b &amp; c</w:t>"))
        XCTAssertFalse(xml.contains("\u{0001}"))
        XCTAssertTrue(xml.contains("<w:b/>"))
        XCTAssertTrue(xml.contains("x</w:t><w:tab/><w:t xml:space=\"preserve\">y</w:t>"))
        XCTAssertTrue(xml.contains("\u{2022} "))
        XCTAssertTrue(xml.hasSuffix("</w:body></w:document>"))
        let data = DocxWriter.data([DocParagraph(.body, text: "hi")])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("[Content_Types].xml"))
        XCTAssertTrue(text.contains("word/document.xml"))
        XCTAssertTrue(text.contains("_rels/.rels"))
    }
}

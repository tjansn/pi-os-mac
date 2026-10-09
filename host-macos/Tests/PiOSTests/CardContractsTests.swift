import XCTest
@testable import PiOSCore

/// Host-side hardening and plain-text fallback for pi-os-ui/1 cards (fixture/inline JSON only).
final class CardContractsTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures")

    private func card(_ name: String) throws -> CardSpec {
        try JSONDecoder().decode(CardSpec.self, from: Data(contentsOf: fixtures.appendingPathComponent("cards/\(name).json")))
    }
    /// A one-child card whose element JSON is substituted verbatim.
    private func decode(element: String, spec extra: String = "") throws -> CardSpec {
        let json = #"{"format":"pi-os-ui/1","root":"root","elements":{"root":{"type":"Answer","props":{},"children":["n1"]},"n1":"#
            + element + "}" + extra + "}"
        return try JSONDecoder().decode(CardSpec.self, from: Data(json.utf8))
    }

    func testBaselineInlineElementsDecode() throws {
        XCTAssertNoThrow(try decode(element: #"{"type":"Markdown","props":{"source":"ok"}}"#))
        XCTAssertNoThrow(try decode(element: #"{"type":"Status","props":{"state":"running","text":"x","progress":null}}"#))
        XCTAssertNoThrow(try decode(element: #"{"type":"Suggestion","props":{"prompt":"go"},"on":{"press":{"action":"askAgent","params":{"prompt":"go"}}}}"#))
        let item = try decode(element: #"{"type":"Item","props":{"title":"a"},"children":[],"on":{"primary":{"action":"openApp","params":{"bundleId":"com.apple.Notes"}}}}"#)
        XCTAssertEqual(item.elements["n1"]?.on["primary"], .openApp(bundleId: "com.apple.Notes"))
    }

    func testDynamicFeaturesAndBindingExtrasAreRejected() {
        let rejected = [
            #"{"type":"Markdown","props":{"source":"x"},"visible":false}"#,
            #"{"type":"Markdown","props":{"source":"x"},"repeat":{"statePath":"/items"}}"#,
            #"{"type":"Markdown","props":{"source":"x"},"watch":{"/a":{"action":"copyText","params":{"text":"x"}}}}"#,
            #"{"type":"Markdown","props":{"source":"x","$computed":"fn"}}"#,
            #"{"type":"KeyValue","props":{"items":[{"key":"a","value":"b","$bindItem":"x"}]}}"#,
            #"{"type":"Markdown","props":"x"}"#,
            #"{"type":"ResultCard","props":{"kind":"math","value":"1"},"on":{"copy":{"action":"copyText","params":{"text":"1"},"confirm":{"title":"t","message":"m"}}}}"#,
            #"{"type":"ResultCard","props":{"kind":"math","value":"1"},"on":{"copy":{"action":"copyText","params":{"text":{"$state":"/secret"}}}}}"#,
            #"{"type":"ResultCard","props":{"kind":"math","value":"1"},"on":{"copy":{"action":"copyText","params":["1"]}}}"#,
            #"{"type":"ResultCard","props":{"kind":"math","value":"1"},"on":{"press":{"action":"copyText","params":{"text":"1"}}}}"#,
            #"{"type":"Item","props":{"title":"a"},"on":{"primary":{"action":"moveToTrash","params":{"token":"tok_12345678"}}}}"#,
        ]
        for element in rejected { XCTAssertThrowsError(try decode(element: element), element) }
        XCTAssertThrowsError(try decode(element: #"{"type":"Markdown","props":{"source":"x"}}"#, spec: #","state":{"secret":1}"#))
    }

    func testBindingsMatchWhatTheUserSees() {
        // A chip that shows one prompt but asks another, or does something else entirely, is rejected.
        for element in [
            #"{"type":"Suggestion","props":{"prompt":"Summarize"},"on":{"press":{"action":"askAgent","params":{"prompt":"Type my password"}}}}"#,
            #"{"type":"Suggestion","props":{"prompt":"Open docs"},"on":{"press":{"action":"openURL","params":{"url":"https://example.com"}}}}"#,
            #"{"type":"ResultCard","props":{"kind":"math","value":"1"},"on":{"copy":{"action":"openURL","params":{"url":"https://example.com"}}}}"#,
            #"{"type":"ResultCard","props":{"kind":"math","value":"1"},"on":{"copy":{"action":"askAgent","params":{"prompt":"1"}}}}"#,
        ] { XCTAssertThrowsError(try decode(element: element), element) }
        // The copied text may differ from the shown value (e.g. without the unit).
        XCTAssertNoThrow(try decode(element: #"{"type":"ResultCard","props":{"kind":"currency","value":"85.93 EUR"},"on":{"copy":{"action":"copyText","params":{"text":"85.93"}}}}"#))
        XCTAssertNoThrow(try decode(element: #"{"type":"Suggestion","props":{"prompt":"Book it"}}"#))
    }

    func testCatalogLimitsAreEnforced() {
        let column = #"{"key":"c","label":"C"}"#
        let columns = { (n: Int) in "[" + Array(repeating: column, count: n).joined(separator: ",") + "]" }
        let rows = { (n: Int) in "[" + Array(repeating: #"{"c":1}"#, count: n).joined(separator: ",") + "]" }
        let items = { (n: Int) in "[" + Array(repeating: #"{"key":"k","value":"v"}"#, count: n).joined(separator: ",") + "]" }
        XCTAssertNoThrow(try decode(element: #"{"type":"Table","props":{"columns":"# + columns(6) + #","rows":"# + rows(50) + "}}"))
        XCTAssertNoThrow(try decode(element: #"{"type":"KeyValue","props":{"items":"# + items(24) + "}}"))
        for element in [
            #"{"type":"Table","props":{"columns":"# + columns(7) + #","rows":[]}}"#,
            #"{"type":"Table","props":{"columns":[],"rows":[]}}"#,
            #"{"type":"Table","props":{"columns":"# + columns(1) + #","rows":"# + rows(51) + "}}",
            #"{"type":"KeyValue","props":{"items":"# + items(25) + "}}",
            #"{"type":"Status","props":{"state":"running","text":"x","progress":1.5}}"#,
            #"{"type":"Status","props":{"state":"running","text":"x","progress":-0.1}}"#,
            #"{"type":"ItemList","props":{"total":-1}}"#,
            #"{"type":"Suggestion","props":{"prompt":""}}"#,
            #"{"type":"Suggestion","props":{"prompt":""# + String(repeating: "a", count: 161) + #""}}"#,
            #"{"type":"Table","props":{"columns":[{"key":"c","label":"C"}],"rows":[{"c":true}]}}"#,
        ] { XCTAssertThrowsError(try decode(element: element), element) }
    }

    func testPlainTextFallbackForFixtures() throws {
        XCTAssertEqual(try card("calc-result").plainText, "15% of 340\n= 51")
        XCTAssertEqual(try card("currency-result").plainText,
                       "100 USD in EUR\n= 85.93 EUR\n1 USD = 0.8593 EUR\nECB reference rate 2026-10-01 · info only")
        XCTAssertEqual(try card("file-list").plainText, """
            Files matching “invoice”
            • Invoice-2026-03.pdf — ~/Documents/Finance (Mar 14)
            • invoice_march_acme.pdf — ~/Downloads (Mar 2)
            • Invoices 2025.numbers — ~/Documents/Finance (Jan 8)
            """)
        XCTAssertEqual(try card("refuse-delete").plainText, "Error: pi-os never deletes files, moves them to the Trash or empties the Trash.")
        let rich = try card("rich-answer").plainText
        XCTAssertTrue(rich.hasPrefix("Here are the **two** cheapest options I found on the page.\n\nBest option\nAirline: Lufthansa\nPrice: €214"))
        XCTAssertTrue(rich.contains("| Airline | Price | Stops |\n| --- | ---: | ---: |\n| Lufthansa | €214 | 0 |\n| Eurowings | €189 | 1 |"))
        XCTAssertTrue(rich.contains("[done] Compared 2 results (100%)"))
        XCTAssertTrue(rich.hasSuffix("• lufthansa.com — https://www.lufthansa.com/de/en/homepage"))
        XCTAssertFalse(rich.contains("Book the Lufthansa flight"), "Suggestions are actions, not answer text")
        let summaryOnly = try JSONDecoder().decode(CardSpec.self, from: Data(#"{"format":"pi-os-ui/1","root":"r","elements":{"r":{"type":"Answer","props":{"summary":"Just this"}}}}"#.utf8))
        XCTAssertEqual(summaryOnly.plainText, "Just this")
        let pipes = try decode(element: #"{"type":"Table","props":{"columns":[{"key":"a","label":"A|B"}],"rows":[{"a":"x|y\nz"},{}]}}"#)
        XCTAssertEqual(pipes.plainText, "| A\\|B |\n| --- |\n| x\\|y z |\n|  |")
    }

    func testSummaryAndActionTypeHelpers() throws {
        XCTAssertEqual(try card("calc-result").summary, "15% of 340 = 51")
        XCTAssertNil(try card("refuse-delete").summary)
        XCTAssertEqual(try card("file-list").actionTypes, ["openFile", "revealFile", "copyPath"])
        for name in ["app-list", "calc-result", "currency-result", "file-list", "refuse-delete", "rich-answer"] {
            XCTAssertTrue(try card(name).usesOnly(CardSpec.modelActionTypes), name)
        }
        let typing = try decode(element: #"{"type":"Item","props":{"title":"a"},"on":{"primary":{"action":"typeIntoPinned","params":{"text":"hi"}}}}"#)
        XCTAssertFalse(typing.usesOnly(CardSpec.modelActionTypes), "Agent cards may not type into the pinned window")
        let system = try decode(element: #"{"type":"Item","props":{"title":"a"},"on":{"primary":{"action":"system","params":{"op":"volume.mute"}}}}"#)
        XCTAssertEqual(system.actionTypes, ["system"])
        XCTAssertFalse(system.usesOnly(CardSpec.modelActionTypes))
    }
}

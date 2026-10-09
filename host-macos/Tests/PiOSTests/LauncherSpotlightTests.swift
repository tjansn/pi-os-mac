import XCTest
@testable import PiOSCore

final class LauncherSpotlightTests: XCTestCase {
    func testLiteralEscapesOnlyQuoteBackslashAndStar() {
        XCTAssertEqual(SpotlightQuery.literal(#"a"b*c\"#), #"a\"b\*c\\"#)
        XCTAssertEqual(SpotlightQuery.literal("Rechnung März?"), "Rechnung März?", "? is not an MDQuery wildcard")
    }

    func testWordPrefixGroupsAndShortExactTerms() throws {
        XCTAssertEqual(try SpotlightQuery.names([["invoice"], ["rechnung"]]),
                       #"(kMDItemFSName == "invoice*"cdw) || (kMDItemFSName == "rechnung*"cdw)"#)
        XCTAssertEqual(try SpotlightQuery.names([["cv"]]), #"(kMDItemFSName == "cv"cdw)"#, "Short terms never get a prefix wildcard")
        XCTAssertEqual(try SpotlightQuery.names([["invoice", "acme"]]), #"(kMDItemFSName == "invoice*"cdw && kMDItemFSName == "acme*"cdw)"#)
        XCTAssertEqual(try SpotlightQuery.names([["visual  studio"], ["  "]]), #"(kMDItemFSName == "visual*"cdw && kMDItemFSName == "studio*"cdw)"#)
        XCTAssertEqual(try SpotlightQuery.names([["Ma\u{0308}rz"]]), #"(kMDItemFSName == "März*"cdw)"#, "Precomposed (NFC)")
    }

    func testTermLimitsAndControlCharactersAreRejected() throws {
        XCTAssertNoThrow(try SpotlightQuery.names([["a", "b", "c"], ["d", "e", "f"]]))
        XCTAssertDomainError(try SpotlightQuery.names([["a", "b", "c"], ["d", "e", "f", "g"]]), "invalid_arguments")
        XCTAssertDomainError(try SpotlightQuery.names([["one two three four five six seven"]]), "invalid_arguments")
        XCTAssertNoThrow(try SpotlightQuery.names([[String(repeating: "x", count: 64)]]))
        XCTAssertDomainError(try SpotlightQuery.names([[String(repeating: "x", count: 65)]]), "invalid_arguments")
        for bad in ["a\u{0007}b", "line\nbreak", "tab\there", "rtl\u{202E}gnp.exe", "zero\u{200B}width", "nul\u{0}x", "sep\u{2028}x"] {
            XCTAssertDomainError(try SpotlightQuery.names([[bad]]), "invalid_arguments")
        }
        XCTAssertDomainError(try SpotlightQuery.names([]), "invalid_arguments")
        XCTAssertDomainError(try SpotlightQuery.names([[], [" "]]), "invalid_arguments")
    }

    func testInjectionAttemptsStayInsideOneLiteral() throws {
        let query = try SpotlightQuery.names([[#"x"cdw||kMDItemFSName=="*"#], [#"a\"#, "*"]])
        // Remove escape sequences; every remaining quote must delimit one of the three literals.
        let unescaped = query.replacingOccurrences(of: #"\\"#, with: "").replacingOccurrences(of: #"\""#, with: "")
            .replacingOccurrences(of: #"\*"#, with: "")
        XCTAssertEqual(unescaped.filter { $0 == "\"" }.count, 6, query)
        XCTAssertEqual(query.components(separatedBy: "kMDItemFSName ==").count - 1, 3, query)
        XCTAssertTrue(query.contains(#"kMDItemFSName == "x\"cdw||kMDItemFSName==\"\**"cdw"#), query)
        XCTAssertTrue(query.contains(#"kMDItemFSName == "\*"cdw"#), query)
    }

    func testContentTypeClauseAndSubstringFallback() throws {
        let names = try SpotlightQuery.names([["invoice"]])
        XCTAssertEqual(try SpotlightQuery.withContentType(names, "com.adobe.pdf"),
                       #"((kMDItemFSName == "invoice*"cdw)) && (kMDItemContentTypeTree == "com.adobe.pdf")"#)
        XCTAssertEqual(try SpotlightQuery.withContentType(names, nil), names)
        for bad in [#"com.adobe.pdf" || kMDItemFSName == "*"#, "", "com adobe", "1abc", "pdf*", String(repeating: "a", count: 129)] {
            XCTAssertDomainError(try SpotlightQuery.withContentType(names, bad), "invalid_arguments")
        }
        XCTAssertEqual(try SpotlightQuery.substringFallback([["invoice"], ["rechnung"]]),
                       #"(kMDItemFSName == "*invoice*"cd) || (kMDItemFSName == "*rechnung*"cd)"#)
        XCTAssertEqual(try SpotlightQuery.substringFallback([["cv", "acme"]]), #"(kMDItemFSName == "cv"cdw && kMDItemFSName == "*acme*"cd)"#)
        XCTAssertNil(try SpotlightQuery.substringFallback([["cv"]]))
        XCTAssertEqual(SpotlightQuery.applications, #"kMDItemContentTypeTree == "com.apple.application-bundle""#)
    }

    func testTrashHiddenLibraryAndBundleInternalsAreExcluded() {
        let home = "/Users/fixture"
        for path in ["/Users/fixture/.Trash/Invoice.pdf", "/Users/fixture/Documents/.hidden/a.pdf", "/Users/fixture/.git/config",
                     "/Users/fixture/dev/app/node_modules/x/invoice.js", "/Users/fixture/Library/Caches/invoice.pdf",
                     "/Users/fixture/Library/Mail/V10/invoice.emlx", "/Users/fixture/Applications/Tool.app/Contents/Resources/invoice.pdf",
                     "/Users/fixture/Pictures/Photos Library.photoslibrary/originals/invoice.jpg", "/Volumes/USB/.Trashes/501/a.pdf",
                     "relative/path.pdf", "/Users/fixture/Documents/Report.rtfd/TXT.rtf", "/Users/fixture/Library",
                     "/Users/fixture/Library/Mobile Documents/com~apple~CloudDocs/.Trash/Invoice.pdf"] {
            XCTAssertTrue(SpotlightResults.excluded(path, home: home), path)
        }
        for path in ["/Users/fixture/Documents/Finance/Invoice-2026-03.pdf", "/Users/fixture/Library/Mobile Documents/com~apple~CloudDocs/Invoice.pdf",
                     "/Users/fixture/Library Notes/invoice.pdf",
                     "/Users/fixture/Applications/Tool.app", "/Users/fixture/Documents/Report.rtfd", "/Users/fixture/Downloads/invoice_march_acme.pdf"] {
            XCTAssertFalse(SpotlightResults.excluded(path, home: home), path)
        }
    }

    func testSelectionFiltersSortsAndTruncates() {
        let home = "/Users/fixture"
        func hit(_ path: String, modified: Double?, lastUsed: Double? = nil) -> SpotlightHit {
            SpotlightHit(path: path, modified: modified.map { Date(timeIntervalSince1970: $0) }, lastUsed: lastUsed.map { Date(timeIntervalSince1970: $0) })
        }
        let hits = [hit("/Users/fixture/a.pdf", modified: 10), hit("/Users/fixture/b.pdf", modified: 30),
                    hit("/Users/fixture/c.pdf", modified: 5, lastUsed: 40), hit("/Users/fixture/a.pdf", modified: 10),
                    hit("/Users/fixture/.Trash/d.pdf", modified: 99), hit("/Users/other/e.pdf", modified: 99), hit("/Users/fixture/n.pdf", modified: nil)]
        let all = SpotlightResults.select(hits, roots: [home], home: home, limit: 10, capped: false)
        XCTAssertEqual(all.hits.map(\.path), ["/Users/fixture/c.pdf", "/Users/fixture/b.pdf", "/Users/fixture/a.pdf", "/Users/fixture/n.pdf"])
        XCTAssertFalse(all.truncated)
        let two = SpotlightResults.select(hits, roots: [home + "/"], home: home, limit: 2, capped: false)
        XCTAssertEqual(two.hits.count, 2); XCTAssertTrue(two.truncated)
        XCTAssertTrue(SpotlightResults.select(hits, roots: [home], home: home, limit: 10, capped: true).truncated)
    }

    func testCandidatesCarryRankingAttributes() {
        let hit = SpotlightHit(path: "/Users/fixture/Documents/Finance/Invoice-2026-03.pdf", name: "Invoice-2026-03.pdf", contentType: "com.adobe.pdf",
                               created: Date(timeIntervalSince1970: 1_773_446_400), modified: Date(timeIntervalSince1970: 1_773_446_400.0004),
                               lastUsed: Date(timeIntervalSince1970: 1_774_051_200), useCount: 3)
        let candidate = SpotlightResults.candidate(hit, token: "tok_3fa8c2d1e9b0")
        XCTAssertEqual(candidate, FileCandidate(token: "tok_3fa8c2d1e9b0", name: "Invoice-2026-03.pdf", path: hit.path, contentType: "com.adobe.pdf",
                                                createdMs: 1_773_446_400_000, modifiedMs: 1_773_446_400_000, lastUsedMs: 1_774_051_200_000,
                                                useCount: 3, isDirectory: false, isPackage: false))
        XCTAssertEqual(SpotlightResults.candidate(SpotlightHit(path: "/Users/f/Folder", contentType: "public.folder"), token: "tok_12345678").name, "Folder")
        XCTAssertTrue(SpotlightResults.kind(contentType: "public.folder").isDirectory)
        XCTAssertEqual(SpotlightResults.kind(contentType: "com.apple.application-bundle").isPackage, true)
        XCTAssertEqual(SpotlightResults.kind(contentType: "com.apple.application-bundle").isDirectory, false)
        XCTAssertEqual(SpotlightResults.kind(contentType: nil).isDirectory, false)
    }
}

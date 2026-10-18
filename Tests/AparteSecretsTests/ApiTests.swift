// API tests on the bundled model. Made-up passwords only: no secret-shaped string
// (provider formats) lives in this repository. The text-by-text equality test
// against the Python reader is ParityTests.

import Foundation
import XCTest
import AparteSecrets

final class ApiTests: XCTestCase {
    private static let secrets = try! Secrets.load()
    private var secrets: Secrets { Self.secrets }

    func testReadsTheModelHeader() {
        XCTAssertEqual(secrets.header.task, "secrets")
        XCTAssertEqual(secrets.header.version, "1.1.0")
        XCTAssertEqual(secrets.header.precision, "int8")
        XCTAssertEqual(secrets.header.subtypes, ["password", "api_key", "token", "private_key", "other"])
    }

    func testFindsAPasswordWithItsKindAndRange() throws {
        let text = "the wifi password is Sunflower77# for the guests"
        let s = try XCTUnwrap(secrets.detect(text).first { $0.text.hasPrefix("Sunflower77") }, "\(secrets.detect(text))")
        XCTAssertEqual(s.subtype, "password")
        XCTAssertEqual(String(text[s.range]), s.text)
        XCTAssertGreaterThan(s.score, 0)
        XCTAssertLessThanOrEqual(s.score, 1)
    }

    func testAnEmptyOrSecretFreeTextGivesNothing() {
        XCTAssertEqual(secrets.detect(""), [])
        XCTAssertEqual(secrets.detect("Can you explain how photosynthesis works?"), [])
    }

    func testMaskAndUnmaskRoundTrip() {
        let text = "Le mot de passe du wifi c'est Biscotte19&, et pour le NAS aussi Biscotte19&"
        let masked = secrets.mask(text)
        XCTAssertFalse(masked.text.contains("Biscotte19&"), "a value found once is masked everywhere: \(masked.text)")
        XCTAssertEqual(masked.secrets.count, 1)
        XCTAssertEqual(secrets.unmask(masked.text, secrets: masked.secrets), text)
    }

    func testIgnoreAndMinScoreAreAppliedAfterTheModel() throws {
        let text = "the wifi password is Sunflower77# for the guests"
        let value = try XCTUnwrap(secrets.detect(text).first).text
        XCTAssertEqual(secrets.detect(text, ignore: [value]), [])
        XCTAssertEqual(secrets.detect(text, ignorePatterns: [try NSRegularExpression(pattern: "^Sunflower")]), [])
        XCTAssertEqual(secrets.detect(text, minScore: 1.01), [])
    }

    func testUtf16OffsetsMatchTheOtherRuntimes() throws {
        let text = "😀 the wifi password is Sunflower77# for the guests"
        let s = try XCTUnwrap(secrets.detect(text).first { $0.text.hasPrefix("Sunflower77") })
        let units = Array(text.utf16)
        XCTAssertEqual(String(decoding: units[s.utf16Range], as: UTF16.self), s.text)
        XCTAssertEqual(String(text[s.range]), s.text)
    }

    func testAVeryLongWordAndAVeryLongTextDoNotFail() {
        // a unit of 256+ characters is in the last length class; a text of 256+ tokens spans several windows
        _ = secrets.detect(String(repeating: "x", count: 5000))
        let long = String(repeating: "the wifi password is Sunflower77# for the guests. ", count: 40)
        XCTAssertGreaterThan(secrets.detect(long).filter { $0.text.hasPrefix("Sunflower77") }.count, 1)
    }

    func testRejectsAFileThatIsNotAModel() {
        XCTAssertThrowsError(try Secrets(data: Data("not a model".utf8)))
    }
}

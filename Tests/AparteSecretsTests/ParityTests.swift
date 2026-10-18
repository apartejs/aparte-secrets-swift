// Equality test: the Swift runtime must give exactly the spans of the Python
// reference implementation (and of the JavaScript runtime), text by text: same
// text, same subtype, score within 2e-4.
//
// The references hold secret-shaped strings, so they are not in this repository:
// they are on Hugging Face (https://huggingface.co/apartejs/aparte-secrets/tree/main/references).
// Point APARTE_SECRETS_REFS at a downloaded references_int8.jsonl; the test is
// reported as skipped otherwise.
//
//     APARTE_SECRETS_REFS=references_int8.jsonl swift test -c release

import Foundation
import XCTest
import AparteSecrets

private struct Reference: Decodable {
    struct RefSpan: Decodable {
        let start: Int
        let end: Int
        let subtype: String
        let score: Double
    }
    let text: String
    let spans: [RefSpan]
}

final class ParityTests: XCTestCase {
    func testGivesTheReferenceSpans() throws {
        guard let path = ProcessInfo.processInfo.environment["APARTE_SECRETS_REFS"] else {
            throw XCTSkip("set APARTE_SECRETS_REFS to a references_int8.jsonl from Hugging Face")
        }
        let secrets = try Secrets.load()
        let lines = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8).split(whereSeparator: \.isNewline)
        var bad: [String] = [], n = 0
        let t0 = Date()
        for line in lines where !line.allSatisfy(\.isWhitespace) {
            let r = try JSONDecoder().decode(Reference.self, from: Data(line.utf8))
            let scalars = Array(r.text.unicodeScalars)
            // Python offsets count code points
            let ref = r.spans.map { s -> (String, String, Double) in
                var v = String.UnicodeScalarView()
                v.append(contentsOf: scalars[s.start..<s.end])
                return (String(v), s.subtype, s.score)
            }
            let mine = secrets.detect(r.text)
            let same = mine.count == ref.count && zip(mine, ref).allSatisfy {
                $0.text == $1.0 && $0.subtype == $1.1 && abs($0.score - $1.2) <= 2e-4
            }
            if !same, bad.count < 10 {
                bad.append("\(r.text.prefix(60))\n  ref \(ref)\n  swift \(mine.map { ($0.text, $0.subtype, $0.score) })")
            }
            n += 1
        }
        print("parity: \(n) texts, \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000 / Double(max(n, 1)))) ms per text")
        XCTAssertGreaterThan(n, 0, "no reference in \(path)")
        XCTAssertTrue(bad.isEmpty, "\(bad.count)+ of \(n) texts differ:\n" + bad.joined(separator: "\n"))
    }
}

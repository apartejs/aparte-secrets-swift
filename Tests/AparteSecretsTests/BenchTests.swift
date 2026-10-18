// Speed on one CPU core, measured exactly as the JavaScript benchmark (packages/secrets/bench/bench.mjs
// in aparte-secrets-model): the chat messages of the aparte-secrets-gold benchmark one by one, then its
// code texts concatenated into one file; median of three rounds.
//
// gold.jsonl is on Hugging Face (https://huggingface.co/datasets/apartejs/aparte-secrets-gold); the test
// is reported as skipped without it.
//
//     APARTE_SECRETS_GOLD=gold.jsonl swift test -c release --filter BenchTests

import Foundation
import XCTest
import AparteSecrets

private struct GoldText: Decodable {
    let group: String
    let text: String
}

final class BenchTests: XCTestCase {
    func testSpeed() throws {
        guard let path = ProcessInfo.processInfo.environment["APARTE_SECRETS_GOLD"] else {
            throw XCTSkip("set APARTE_SECRETS_GOLD to a gold.jsonl from Hugging Face")
        }
        let secrets = try Secrets.load()
        let gold = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(GoldText.self, from: Data($0.utf8)) }
        let chat = gold.filter { $0.group.hasPrefix("chat") }.map(\.text)
        let code = gold.filter { $0.group == "code" }.map(\.text).joined(separator: "\n")

        func median(_ rounds: Int, _ f: () -> Void) -> Double {
            (0..<rounds).map { _ -> Double in
                let t0 = DispatchTime.now().uptimeNanoseconds
                f()
                return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            }.sorted()[rounds / 2]
        }
        for t in chat.prefix(20) { _ = secrets.detect(t) }
        let chatMs = median(3) { for t in chat { _ = secrets.detect(t) } }
        let codeMs = median(3) { _ = secrets.detect(code) }
        let chars = code.utf16.count
        print(String(format: "bench: {\"chat\": {\"texts\": %d, \"mean_chars\": %d, \"ms_per_text\": %.2f}, \"code\": {\"chars\": %d, \"us_per_char\": %.1f}}",
                     chat.count, chat.map(\.utf16.count).reduce(0, +) / chat.count, chatMs / Double(chat.count), chars, codeMs * 1000 / Double(chars)))
    }
}

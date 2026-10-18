// AparteSecrets — finds passwords, API keys, tokens and private keys in text, on-device.
//
// Reads the `.bin` model files published at https://huggingface.co/apartejs/aparte-secrets
// (format 1); the int8 model is bundled. No dependency.
//
//     import AparteSecrets
//
//     let secrets = try Secrets.load()
//     secrets.detect("the wifi password is Sunflower77# for the guests")
//     // [Span(text: "Sunflower77#", subtype: "password", score: …)]
//
// It gives exactly the spans of the JavaScript runtime (@aparte/secrets on npm) and
// of the Python reference implementation; the tests check it text by text.

import Foundation

/// A secret found in the text.
public struct Span: Sendable, Hashable, CustomStringConvertible {
    /// Where it is in the text: `text[span.range] == span.text`.
    public let range: Range<String.Index>
    /// The same place as UTF-16 offsets, the `start` and `end` of the JavaScript and Kotlin runtimes.
    public let utf16Range: Range<Int>
    /// The secret itself.
    public let text: String
    /// `password`, `api_key`, `token`, `private_key` or `other`.
    public let subtype: String
    /// The model's confidence, from 0 to 1.
    public let score: Double

    public var description: String {
        "Span(\(utf16Range.lowerBound)..<\(utf16Range.upperBound), text: \"\(text)\", subtype: \(subtype), score: \(score))"
    }
}

/// The result of `Secrets.mask`: the masked text, and each placeholder's value (keep it on the device).
public struct Masked: Sendable, Equatable {
    public let text: String
    public let secrets: [String: String]
}

/// The detector: load a model file once, then scan as many texts as you like.
/// It holds no mutable state and can be shared across threads.
public final class Secrets: Sendable {
    /// The name of the bundled model file.
    public static let modelFile = "secrets-v1.1-int8.bin"

    /// Where the bundled model file is.
    public static var modelURL: URL? {
        Bundle.module.url(forResource: "secrets-v1.1-int8", withExtension: "bin")
    }

    /// Load the bundled model (int8). Load it once and keep the `Secrets`:
    /// it is immutable and safe to share across threads.
    public static func load() throws -> Secrets {
        guard let url = modelURL else { throw SecretsError.malformed("the bundled model \(modelFile) is missing") }
        return try Secrets(contentsOf: url)
    }

    /// The model file's header: version, precision, dimensions, subtypes.
    public let header: ModelHeader
    let tokenizer: Tokenizer
    let model: Model
    let transitions: Transitions

    /// Load a model from the contents of a `.bin` file.
    public init(data: Data) throws {
        let (header, merges, weights) = try readModel(data)
        self.header = header
        tokenizer = Tokenizer(header: header, merges: merges)
        model = try Model(header: header, weights: weights)
        guard model.classes == 1 + 4 * header.subtypes.count else {
            throw SecretsError.malformed("\(header.subtypes.count) subtypes for \(model.classes) classes")
        }
        guard header.window > 0, header.stride > 0, header.unitLengthClasses > 0 else {
            throw SecretsError.malformed("inconsistent window")
        }
        transitions = Transitions(model.classes)
    }

    /// Load a model from a `.bin` file on disk or in a bundle.
    public convenience init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    /// Every secret found in the text, in text order. The model reports raw spans;
    /// `minScore`, `ignore` (exact values) and `ignorePatterns` are the caller's
    /// policy, applied after it.
    public func detect(
        _ text: String,
        minScore: Double = 0,
        ignore: Set<String> = [],
        ignorePatterns: [NSRegularExpression] = []
    ) -> [Span] {
        let spans = raw(text)
        if minScore <= 0, ignore.isEmpty, ignorePatterns.isEmpty { return spans }
        return spans.filter { s in
            s.score >= minScore && !ignore.contains(s.text) && !ignorePatterns.contains {
                $0.firstMatch(in: s.text, range: NSRange(s.text.startIndex..., in: s.text)) != nil
            }
        }
    }

    /// Replace every secret with a placeholder (`[PASSWORD_1]`, `[API_KEY_2]`…),
    /// reversibly. A value found once is masked everywhere it appears: the model
    /// may only flag the occurrence whose context gives it away.
    public func mask(
        _ text: String,
        minScore: Double = 0,
        ignore: Set<String> = [],
        ignorePatterns: [NSRegularExpression] = [],
        placeholder: (_ subtype: String, _ n: Int) -> String = { subtype, n in "[\(subtype.uppercased())_\(n)]" }
    ) -> Masked {
        // UTF-16 offsets throughout, as the JavaScript runtime searches the text
        let units = Array(text.utf16)
        let found = detect(text, minScore: minScore, ignore: ignore, ignorePatterns: ignorePatterns)
        var all: [(start: Int, end: Int, text: String, subtype: String)] =
            found.map { ($0.utf16Range.lowerBound, $0.utf16Range.upperBound, $0.text, $0.subtype) }
        var values: [String] = []
        for s in found where !values.contains(s.text) { values.append(s.text) }
        for value in values {
            let subtype = found.first { $0.text == value }!.subtype
            let v = Array(value.utf16)
            var i = indexOf(v, in: units, from: 0)
            while let at = i {
                let end = at + v.count
                if !all.contains(where: { $0.start < end && at < $0.end }) { all.append((at, end, value, subtype)) }
                i = indexOf(v, in: units, from: end)
            }
        }
        all.sort { $0.start < $1.start }
        var out = "", pos = 0, n = 0
        var seen: [String: String] = [:], secrets: [String: String] = [:]
        for s in all where s.start >= pos {
            let ph: String
            if let known = seen[s.text] { ph = known } else {
                n += 1
                ph = placeholder(s.subtype, n)
                seen[s.text] = ph; secrets[ph] = s.text
            }
            out += String(decoding: units[pos..<s.start], as: UTF16.self) + ph
            pos = s.end
        }
        out += String(decoding: units[pos...], as: UTF16.self)
        return Masked(text: out, secrets: secrets)
    }

    /// Put the values back: the inverse of `mask` (e.g. on an AI's answer).
    public func unmask(_ text: String, secrets: [String: String]) -> String {
        var out = text
        // longest placeholder first, so that none replaces part of another
        for ph in secrets.keys.sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }) {
            out = out.replacingOccurrences(of: ph, with: secrets[ph]!)
        }
        return out
    }

    // MARK: - decoding

    private func raw(_ text: String) -> [Span] {
        let cps = Array(text.unicodeScalars)
        let enc = tokenizer.encode(cps)
        let n = enc.ids.count
        if n == 0 { return [] }
        let c = model.classes
        let unitLength = enc.units.map { lengthClass(cps, $0, header.unitLengthClasses) }
        var total = [Double](repeating: 0, count: n * c), count = [Double](repeating: 0, count: n)
        for d in windows(n, header.window, header.stride) {
            let end = min(d + header.window, n), len = end - d
            let z = model.logits(Array(enc.ids[d..<end]), (d..<end).map { unitLength[enc.unitOf[$0]] })
            // one decision per unit inside the window: mean of its tokens' logits, then log-softmax
            let u0 = enc.unitOf[d], nu = enc.unitOf[end - 1] - u0 + 1
            var sums = [Double](repeating: 0, count: nu * c), cnt = [Double](repeating: 0, count: nu)
            for t in 0..<len {
                let u = enc.unitOf[d + t] - u0
                cnt[u] += 1
                for k in 0..<c { sums[u * c + k] += Double(z[t * c + k]) }
            }
            for t in 0..<len {
                let u = enc.unitOf[d + t] - u0
                var mx = -Double.infinity
                for k in 0..<c { mx = max(mx, sums[u * c + k] / cnt[u]) }
                var s = 0.0
                for k in 0..<c { s += exp(sums[u * c + k] / cnt[u] - mx) }
                let lse = mx + log(s)
                for k in 0..<c { total[(d + t) * c + k] += sums[u * c + k] / cnt[u] - lse }
                count[d + t] += 1
            }
        }
        // mean log-probabilities per unit (units that have tokens, in text order)
        var index = [Int](repeating: -1, count: enc.units.count), kept: [Int] = []
        for u in enc.unitOf where index[u] < 0 { index[u] = kept.count; kept.append(u) }
        let kn = kept.count
        var lp = [Double](repeating: 0, count: kn * c), nk = [Double](repeating: 0, count: kn)
        for t in 0..<n {
            let i = index[enc.unitOf[t]]
            nk[i] += 1
            for k in 0..<c { lp[i * c + k] += total[t * c + k] / count[t] }
        }
        for i in 0..<kn { for k in 0..<c { lp[i * c + k] /= nk[i] } }
        let path = transitions.viterbi(lp, kn)

        var utf16 = [Int](repeating: 0, count: cps.count + 1)
        for (i, s) in cps.enumerated() { utf16[i + 1] = utf16[i] + s.utf16.count }
        var out: [Span] = [], first = -1
        for i in 0..<kn {
            let e = path[i]
            if e == 0 { first = -1; continue }
            let tag = (e - 1) % 4
            if tag == 0 || tag == 3 { first = i }
            if (tag == 2 || tag == 3) && first >= 0 {
                var a = enc.units[kept[first]].lowerBound
                let b = enc.units[kept[i]].upperBound
                while a < b, isPythonSpace(cps[a]) { a += 1 }
                var score = Double.infinity
                for j in first...i { score = min(score, 1 - exp(lp[j * c])) }
                let lo = String.Index(utf16Offset: utf16[a], in: text), hi = String.Index(utf16Offset: utf16[b], in: text)
                out.append(Span(range: lo..<hi, utf16Range: utf16[a]..<utf16[b], text: String(text[lo..<hi]),
                                subtype: header.subtypes[(e - 1) / 4], score: ((score * 1e4) + 0.5).rounded(.down) / 1e4))
                first = -1
            }
        }
        return out
    }
}

/// Length class of a unit: log2 scale of its non-blank characters (0 for blank), capped at the model's classes.
private func lengthClass(_ s: [Unicode.Scalar], _ r: Range<Int>, _ classes: Int) -> Int {
    var a = r.lowerBound, b = r.upperBound
    while a < b, isPythonSpace(s[a]) { a += 1 }
    while b > a, isPythonSpace(s[b - 1]) { b -= 1 }
    let n = b - a
    return n == 0 ? 0 : min(Int.bitWidth - n.leadingZeroBitCount, classes - 1)
}

private func windows(_ n: Int, _ size: Int, _ stride: Int) -> [Int] {
    if n <= size { return [0] }
    var out: [Int] = [], d = 0
    while d <= n - size { out.append(d); d += stride }
    if out[out.count - 1] + size < n { out.append(n - size) }
    return out
}

/// JavaScript's `indexOf` on UTF-16 units.
private func indexOf(_ needle: [UInt16], in hay: [UInt16], from: Int) -> Int? {
    if needle.isEmpty || needle.count > hay.count { return nil }
    var i = from
    while i + needle.count <= hay.count {
        if hay[i] == needle[0] {
            var j = 1
            while j < needle.count, hay[i + j] == needle[j] { j += 1 }
            if j == needle.count { return i }
        }
        i += 1
    }
    return nil
}

/// Allowed BIOES moves, one subtype per span: state k > 0 is subtype (k-1)/4, tag (k-1)%4 (B, I, E, S).
struct Transitions: Sendable {
    let c: Int
    let m: [Double], start: [Double], end: [Double]

    init(_ c: Int) {
        self.c = c
        func tag(_ k: Int) -> Int { k == 0 ? -1 : (k - 1) % 4 }
        func sub(_ k: Int) -> Int { k == 0 ? -1 : (k - 1) / 4 }
        func opens(_ k: Int) -> Bool { k == 0 || tag(k) == 0 || tag(k) == 3 }
        var m = [Double](repeating: -1e9, count: c * c)
        for j in 0..<c {
            for k in 0..<c {
                let ok = tag(j) == 0 || tag(j) == 1 ? (tag(k) == 1 || tag(k) == 2) && sub(k) == sub(j) : opens(k)
                if ok { m[j * c + k] = 0 }
            }
        }
        self.m = m
        start = (0..<c).map { opens($0) ? 0 : -1e9 }
        end = (0..<c).map { $0 == 0 || tag($0) == 2 || tag($0) == 3 ? 0 : -1e9 }
    }

    func viterbi(_ logp: [Double], _ len: Int) -> [Int] {
        var score = (0..<c).map { logp[$0] + start[$0] }
        var back = [Int](repeating: 0, count: len * c)
        for t in 1..<max(len, 1) {
            var next = [Double](repeating: 0, count: c)
            for k in 0..<c {
                var best = -Double.infinity, arg = 0
                for j in 0..<c { let v = score[j] + m[j * c + k]; if v > best { best = v; arg = j } }
                back[t * c + k] = arg
                next[k] = best + logp[t * c + k]
            }
            score = next
        }
        var k = 0, best = -Double.infinity
        for j in 0..<c where score[j] + end[j] > best { best = score[j] + end[j]; k = j }
        var path = [Int](repeating: 0, count: len)
        path[len - 1] = k
        var t = len - 1
        while t >= 1 { k = back[t * c + k]; path[t - 1] = k; t -= 1 }
        return path
    }
}

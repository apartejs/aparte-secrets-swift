// Units, then byte-level BPE inside each unit, reproducing the JavaScript runtime
// exactly. Positions are counted in Unicode scalars of the text; the public API
// converts them to string indices and UTF-16 offsets.

// MARK: - character classes

/// `\p{L}`: a letter of any script.
@inline(__always)
func isLetter(_ s: Unicode.Scalar) -> Bool {
    switch s.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
    default: return false
    }
}

/// `\p{N}`: a number of any kind.
@inline(__always)
func isNumber(_ s: Unicode.Scalar) -> Bool {
    switch s.properties.generalCategory {
    case .decimalNumber, .letterNumber, .otherNumber: return true
    default: return false
    }
}

/// `[\p{L}\p{N}_\-]`: what a unit is made of.
@inline(__always)
func isUnitChar(_ s: Unicode.Scalar) -> Bool { s == "_" || s == "-" || isLetter(s) || isNumber(s) }

/// JavaScript's `\s` (WhiteSpace and LineTerminator), used by the unit split.
@inline(__always)
func isJSSpace(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
    default: return false
    }
}

/// Python's `str.isspace()`, used to measure a unit and to trim a span. It differs
/// from JavaScript's `\s`: it adds U+001C–U+001F and U+0085, and lacks U+FEFF.
@inline(__always)
func isPythonSpace(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x09...0x0D, 0x1C...0x1F, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
        return true
    default: return false
    }
}

// MARK: - units

/// The model's units, the JavaScript regex `` ?[\p{L}\p{N}_\-]+| ?[^\s\p{L}\p{N}_\-]|\s+(?!\S)|\s+``
/// written out as a scanner: runs of letters, digits, `_` and `-` with an optional
/// leading space; every other symbol alone (with an optional leading space);
/// whitespace. The alternatives are tried in that order and the first that matches wins.
func units(_ s: [Unicode.Scalar]) -> [Range<Int>] {
    var out: [Range<Int>] = []
    let n = s.count
    let space: Unicode.Scalar = " "
    var i = 0
    while i < n {
        var j: Int
        let spaceThen = s[i] == space && i + 1 < n
        if isUnitChar(s[i]) || (spaceThen && isUnitChar(s[i + 1])) {
            j = s[i] == space ? i + 1 : i
            while j < n, isUnitChar(s[j]) { j += 1 }
        } else if spaceThen && !isJSSpace(s[i + 1]) {
            j = i + 2                                 // a space and one symbol
        } else if !isJSSpace(s[i]) {
            j = i + 1                                 // one symbol
        } else {
            // whitespace: `\s+(?!\S)` keeps the last space for what follows when the run is longer than one
            j = i
            while j < n, isJSSpace(s[j]) { j += 1 }
            if j < n, j - i >= 2 { j -= 1 }
        }
        out.append(i..<j)
        i = j
    }
    return out
}

// MARK: - BPE

@inline(__always)
func utf8(_ v: UInt32) -> [UInt8] {
    switch v {
    case 0..<0x80: return [UInt8(v)]
    case 0x80..<0x800: return [UInt8(0xC0 | v >> 6), UInt8(0x80 | v & 0x3F)]
    case 0x800..<0x10000: return [UInt8(0xE0 | v >> 12), UInt8(0x80 | (v >> 6) & 0x3F), UInt8(0x80 | v & 0x3F)]
    default: return [UInt8(0xF0 | v >> 18), UInt8(0x80 | (v >> 12) & 0x3F), UInt8(0x80 | (v >> 6) & 0x3F), UInt8(0x80 | v & 0x3F)]
    }
}

/// Tokens (ids and the unit of each) and units (their ranges, in Unicode scalars).
struct Encoded {
    let ids: [Int]
    let unitOf: [Int]
    let units: [Range<Int>]
}

struct Tokenizer: Sendable {
    let byteIds: [Int]
    let base: Int
    let rank: [Int: Int]

    init(header: ModelHeader, merges: [UInt16]) {
        byteIds = header.byteIds
        base = header.mergesBase
        var r: [Int: Int] = [:]
        r.reserveCapacity(merges.count / 2)
        for k in 0..<(merges.count / 2) { r[Int(merges[2 * k]) * 65536 + Int(merges[2 * k + 1])] = k }
        rank = r
    }

    func encode(_ text: [Unicode.Scalar]) -> Encoded {
        var ids: [Int] = [], unitOf: [Int] = []
        let pieces = units(text)
        for (u, piece) in pieces.enumerated() {
            var tokens: [Int] = []
            for k in piece { for b in utf8(text[k].value) { tokens.append(byteIds[Int(b)]) } }
            while tokens.count > 1 {                 // merge the lowest-ranked pair first
                var best = -1, at = -1
                for j in 0..<(tokens.count - 1) {
                    if let r = rank[tokens[j] * 65536 + tokens[j + 1]], best < 0 || r < best { best = r; at = j }
                }
                if best < 0 { break }
                tokens[at] = base + best
                tokens.remove(at: at + 1)
            }
            for t in tokens { ids.append(t); unitOf.append(u) }
        }
        return Encoded(ids: ids, unitOf: unitOf, units: pieces)
    }
}

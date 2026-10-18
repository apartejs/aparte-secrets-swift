import Foundation

/// An error raised while reading a model file.
public enum SecretsError: Error, CustomStringConvertible, Sendable {
    /// The data does not start with the `LMAP` magic of an aparte model.
    case notAModelFile
    /// The file is an aparte model for another task (e.g. the titler).
    case wrongTask(String?)
    /// The file uses a format this runtime does not read.
    case unsupportedFormat(Int)
    /// The file is truncated or inconsistent.
    case malformed(String)

    public var description: String {
        switch self {
        case .notAModelFile: return "not an aparte model file"
        case .wrongTask(let t): return "not an aparte-secrets model (task \(t ?? "none"))"
        case .unsupportedFormat(let f): return "model format \(f) is not supported by this runtime (format 1)"
        case .malformed(let why): return "malformed model file: \(why)"
        }
    }
}

/// The JSON header of a model file: what the model is, and how to run it.
public struct ModelHeader: Decodable, Sendable {
    public let format: Int?
    public let task: String?
    public let name: String?
    /// The version of the weights, e.g. `"1.1.0"`.
    public let version: String?
    public let model: String?
    /// `"fp32"`, `"int8"`, `"int4"` or `"int3"`.
    public let precision: String?
    public let dim: Int
    public let layers: Int
    public let heads: Int
    public let dimEmb: Int
    public let vocab: Int?
    public let mergesBase: Int
    public let maxPos: Int
    public let window: Int
    public let stride: Int
    public let unitLengthClasses: Int
    let labels: Labels
    let byteIds: [Int]
    let tensors: [Tensor]

    /// The kinds of secret the model tells apart: `password`, `api_key`, `token`, `private_key`, `other`.
    public var subtypes: [String] { labels.subtypes }

    struct Labels: Decodable, Sendable {
        let subtypes: [String]
    }

    struct Tensor: Decodable, Sendable {
        let name: String
        let shape: [Int]
        let type: String
        let bytes: Int
    }

    enum CodingKeys: String, CodingKey {
        case format, task, name, version, model, precision, dim, layers, heads,
             dimEmb = "dim_emb", vocab, mergesBase = "merges_base", maxPos = "max_pos", window, stride,
             unitLengthClasses = "unit_length_classes", labels, byteIds = "byte_ids", tensors
    }
}

// MARK: - reading

/// Little-endian readers over the raw bytes of the file.
private struct Reader {
    let b: [UInt8]

    func u16(_ p: Int) -> UInt16 { UInt16(b[p]) | UInt16(b[p + 1]) << 8 }
    func u32(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24 }
    func f32(_ p: Int) -> Float {
        Float(bitPattern: UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24)
    }
}

/// IEEE half precision to a Double, exactly as the JavaScript runtime computes it.
@inline(__always)
func fp16(_ u: UInt16) -> Double {
    let s: Double = (u & 0x8000) != 0 ? -1 : 1
    let e = Int((u >> 10) & 0x1f), m = Double(u & 0x3ff)
    if e == 0 { return s * m * 0x1p-24 }
    if e == 31 { return m != 0 ? .nan : s * .infinity }
    return s * (1 + m / 1024) * Double(sign: .plus, exponent: e - 15, significand: 1)
}

/// A bit stream, least significant bit first: `n` signed integers of `bits` bits.
func unpackBits(_ bytes: ArraySlice<UInt8>, count n: Int, bits: Int) -> [Int32] {
    var out = [Int32](repeating: 0, count: n)
    let base = bytes.startIndex
    if bits == 8 {
        for i in 0..<n { out[i] = Int32(bytes[base + i]) - 128 }
        return out
    }
    let offset = Int32(1) << Int32(bits - 1)
    var pos = 0
    for i in 0..<n {
        var v: Int32 = 0
        for k in 0..<bits {
            if bytes[base + (pos >> 3)] & UInt8(1 << (pos & 7)) != 0 { v |= Int32(1) << Int32(k) }
            pos += 1
        }
        out[i] = v - offset
    }
    return out
}

/// Only the task, read before the full header: a titler file must say so, not fail on a missing key.
private struct TaskOnly: Decodable { let task: String? }

/// Parse a model file: its header, its BPE merges, and its weights dequantized to Float.
func readModel(_ data: Data) throws -> (ModelHeader, [UInt16], [String: [Float]]) {
    let bytes = [UInt8](data)
    let r = Reader(b: bytes)
    guard bytes.count >= 8, bytes[0] == 0x4C, bytes[1] == 0x4D, bytes[2] == 0x41, bytes[3] == 0x50 else {
        throw SecretsError.notAModelFile
    }
    var p = 4
    let headerLength = r.u32(p); p += 4
    guard p + headerLength + 4 <= bytes.count else { throw SecretsError.malformed("header runs past the end") }
    let json = Data(bytes[p..<(p + headerLength)])
    let task = (try? JSONDecoder().decode(TaskOnly.self, from: json))?.task
    guard task == "secrets" else { throw SecretsError.wrongTask(task) }
    let header: ModelHeader
    do {
        header = try JSONDecoder().decode(ModelHeader.self, from: json)
    } catch {
        throw SecretsError.malformed("header: \(error)")
    }
    p += headerLength
    if let f = header.format, f != 1 { throw SecretsError.unsupportedFormat(f) }
    guard header.byteIds.count == 256 else { throw SecretsError.malformed("byte_ids must have 256 entries") }

    let mergesLength = r.u32(p); p += 4
    guard p + mergesLength <= bytes.count else { throw SecretsError.malformed("merges run past the end") }
    var merges = [UInt16](repeating: 0, count: mergesLength / 2)
    for k in 0..<merges.count { merges[k] = r.u16(p + 2 * k) }
    p += mergesLength

    var weights: [String: [Float]] = [:]
    for t in header.tensors {
        let count = t.shape.reduce(1, *)
        guard t.bytes >= 0, p + t.bytes <= bytes.count else { throw SecretsError.malformed("tensor \(t.name) runs past the end") }
        var w = [Float](repeating: 0, count: count)
        switch t.type {
        case "f32":
            for i in 0..<count { w[i] = r.f32(p + 4 * i) }
        case "f16":
            for i in 0..<count { w[i] = Float(fp16(r.u16(p + 2 * i))) }
        default:
            // quantized rows: packed integers, then one fp16 scale per row
            guard t.type.first == "q", let bits = Int(t.type.dropFirst()), (1...8).contains(bits),
                  let rows = t.shape.first, rows > 0 else {
                throw SecretsError.malformed("tensor \(t.name) has an unknown type \(t.type)")
            }
            let cols = count / rows
            let packedLength = (count * bits + 7) / 8
            let q = unpackBits(bytes[p..<(p + packedLength)], count: count, bits: bits)
            for row in 0..<rows {
                let scale = fp16(r.u16(p + packedLength + 2 * row))
                for c in 0..<cols { w[row * cols + c] = Float(Double(q[row * cols + c]) * scale) }
            }
        }
        weights[t.name] = w
        p += t.bytes
    }
    return (header, merges, weights)
}

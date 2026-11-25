import Foundation
import CommonCrypto

// MARK: - Byte helpers

extension Data {
    func hexString() -> String { map { String(format: "%02x", $0) }.joined() }
}

func u16le(_ v: UInt16) -> Data {
    var x = v.littleEndian
    return withUnsafeBytes(of: &x) { Data($0) }
}

func u32le(_ v: UInt32) -> Data {
    var x = v.littleEndian
    return withUnsafeBytes(of: &x) { Data($0) }
}

func hexValue(_ bytes: Data) -> UInt64 {
    let s = String(decoding: bytes, as: UTF8.self)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    return UInt64(s, radix: 16) ?? 0
}

/// Format a 64-bit value as upper-case hexadecimal.
///
/// `String(format: "%X", value)` reads its argument as a 32-bit `int`, so it
/// silently truncates the high half of a `UInt64` — which would corrupt the
/// Diffie–Hellman public value and the session key. This does it properly.
func hexString(_ value: UInt64, width: Int = 0) -> String {
    let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7",
                               "8", "9", "A", "B", "C", "D", "E", "F"]
    var bytes: [UInt8] = []
    var v = value
    repeat {
        bytes.append(digits[Int(v & 0xF)].asciiValue!)
        v >>= 4
    } while v != 0

    if bytes.count < width {
        bytes.append(contentsOf: Array(repeating: UInt8(ascii: "0"), count: width - bytes.count))
    }
    return String(decoding: bytes.reversed(), as: UTF8.self)
}

// MARK: - AES-ECB

/// AES in ECB mode with no implicit padding — the StickerPix protocol pads
/// with NUL bytes itself and encrypts raw 16-byte blocks.
enum AES {
    static func ecb(_ key: Data, _ data: Data, decrypt: Bool = false) -> Data {
        precondition(key.count == 16, "AES key must be 16 bytes")
        let keyBytes = [UInt8](key)
        let dataBytes = [UInt8](data)
        var outBuf = [UInt8](repeating: 0, count: max(data.count, 16))
        let outCap = outBuf.count
        var outLen = 0
        let op = decrypt ? CCOperation(kCCDecrypt) : CCOperation(kCCEncrypt)
        dataBytes.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            outBuf.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                keyBytes.withUnsafeBytes { (kp: UnsafeRawBufferPointer) in
                    CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            kp.baseAddress, keyBytes.count, nil,
                            src.baseAddress, dataBytes.count,
                            dst.baseAddress, outCap, &outLen)
                }
            }
        }
        return Data(outBuf[0..<outLen])
    }

    /// Zero-pad to the next 16-byte boundary, then encrypt.
    static func encryptPadded(_ key: Data, _ data: Data) -> Data {
        var padded = data
        if padded.count % 16 != 0 {
            padded += Data(repeating: 0, count: 16 - (padded.count % 16))
        }
        return ecb(key, padded)
    }
}

// MARK: - 64-bit modular arithmetic

/// Multiply two 64-bit values modulo `m` without overflowing.
///
/// The naive `a * b % m` traps on overflow, so the 128-bit product is reduced
/// bit by bit using a 128-bit running remainder.
func mulmod(_ a: UInt64, _ b: UInt64, _ m: UInt64) -> UInt64 {
    precondition(m > 0)
    let (hi, lo) = a.multipliedFullWidth(by: b)
    var rHi: UInt64 = 0
    var rLo: UInt64 = 0
    for word in [hi, lo] {
        for i in stride(from: 63, through: 0, by: -1) {
            let bit = (word >> UInt64(i)) & 1
            rHi = (rHi << 1) | (rLo >> 63)
            rLo = (rLo << 1) | bit
            if rHi != 0 {
                // The running value is 2^64 + rLo, which is always >= m here.
                rLo = rLo &- m
                rHi = rHi &- 1
            } else if rLo >= m {
                rLo = rLo &- m
            }
        }
    }
    return rLo
}

/// Modular exponentiation: `base^exp mod m`.
func modexp(_ base: UInt64, _ exp: UInt64, _ m: UInt64) -> UInt64 {
    precondition(m > 1)
    var result: UInt64 = 1
    var b = base % m
    var e = exp
    while e > 0 {
        if e & 1 == 1 { result = mulmod(result, b, m) }
        b = mulmod(b, b, m)
        e >>= 1
    }
    return result
}

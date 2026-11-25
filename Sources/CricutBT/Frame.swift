import Foundation

// MARK: - Frame layout
//
//  offset  size  meaning
//  0       1     start marker 0x7E
//  1–2     2     fixed 64 00
//  3       1     application channel
//  4       1     command
//  5       1     payload type (0x03 JSON, 0x02 file data)
//  6–9     4     zero
//  10–13   4     sequence
//  14–15   2     fragment count
//  16–17   2     fragment index
//  18–19   2     payload length (low 10 bits) + flags
//  20..    n     payload
//  -2      1     checksum: sum of bytes 1..<n+1 modulo 256
//  -1      1     end marker 0x7E

enum Frame {
    static let headerSize = 20
    static let trailerSize = 2
    static let maxPayload = 1023

    /// Application channel byte inside a packet.
    enum Channel {
        static let control: UInt8 = 0xFF   // handshake
        static let json: UInt8 = 0x01      // JSON request/response
        static let fileTransfer: UInt8 = 0x02
    }

    /// Command byte inside a packet.
    enum Command {
        static let hello: UInt8 = 0x10
        static let dhInfo: UInt8 = 0x11
        static let dhConfirm: UInt8 = 0x12
        static let dhResult: UInt8 = 0x13
        static let request: UInt8 = 0x06
        static let response: UInt8 = 0x07
    }

    enum PayloadType {
        static let file: UInt8 = 0x02
        static let json: UInt8 = 0x03
    }

    static func build(command: UInt8,
                      body: Data,
                      channel: UInt8 = Channel.control,
                      sequence: UInt32 = 0,
                      encrypted: Bool = false,
                      fragments: UInt16 = 0,
                      fragment: UInt16 = 0,
                      fileTransfer: Bool = false,
                      payloadType: UInt8 = PayloadType.json) -> Data {
        precondition(body.count <= maxPayload, "payload exceeds single-frame limit")
        var flags = UInt16(body.count)
        if encrypted { flags |= UInt16(5 << 10) }   // AES indicator
        if fileTransfer { flags |= UInt16(0x2000) } // file-transfer flag

        var packet = Data([0x7E, 0x64, 0x00, channel, command, payloadType])
        packet += u32le(0)
        packet += u32le(sequence)
        packet += u16le(fragments)
        packet += u16le(fragment)
        packet += u16le(flags)
        packet += body

        let checksum = packet.dropFirst().reduce(UInt8(0)) { $0 &+ $1 }
        packet.append(checksum)
        packet.append(0x7E)
        return packet
    }

    /// Parsed view of a received frame.
    struct Parsed {
        let channel: UInt8
        let command: UInt8
        let payloadType: UInt8
        let sequence: UInt32
        let fragments: UInt16
        let fragment: UInt16
        let flags: UInt16
        let body: Data

        var payloadLength: Int { Int(flags & 0x03FF) }
        var isEncrypted: Bool { ((flags >> 10) & 7) == 5 }
    }

    /// Validate and split one frame out of `buffer`; returns nil when more
    /// bytes are needed.
    static func parse(_ buffer: inout Data) -> Parsed? {
        guard buffer.count >= headerSize else { return nil }
        let bytes = [UInt8](buffer)
        let flags = UInt16(bytes[18]) | (UInt16(bytes[19]) << 8)
        let total = Int(flags & 0x03FF) + headerSize + trailerSize
        guard buffer.count >= total else { return nil }

        let frameBytes = Array(buffer.prefix(total))
        buffer.removeFirst(total)

        guard frameBytes[0] == 0x7E, frameBytes[total - 1] == 0x7E else {
            throwFrameError("bad frame markers")
            return nil
        }
        let expected = frameBytes[1..<(total - 2)].reduce(UInt8(0)) { $0 &+ $1 }
        guard frameBytes[total - 2] == expected else {
            throwFrameError("bad checksum")
            return nil
        }

        let seq = UInt32(bytes[10]) | (UInt32(bytes[11]) << 8) | (UInt32(bytes[12]) << 16) | (UInt32(bytes[13]) << 24)
        let frags = UInt16(bytes[14]) | (UInt16(bytes[15]) << 8)
        let frag = UInt16(bytes[16]) | (UInt16(bytes[17]) << 8)

        return Parsed(channel: bytes[3],
                      command: bytes[4],
                      payloadType: bytes[5],
                      sequence: seq,
                      fragments: frags,
                      fragment: frag,
                      flags: flags,
                      body: Data(frameBytes[headerSize..<(total - 2)]))
    }

    private static func throwFrameError(_ message: String) {
        FileHandle.standardError.write(Data("frame error: \(message)\n".utf8))
    }
}

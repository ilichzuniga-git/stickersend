import Foundation
import IOBluetooth

/// A live session with the printer: the Diffie–Hellman handshake followed by
/// encrypted JSON requests on application channel 0x01.
final class PrinterSession {
    let device: IOBluetoothDevice?
    private(set) var sessionKey: Data?
    private var requestID = 0

    /// The transport this session runs over.
    let transport: ByteChannel

    init(device: IOBluetoothDevice, transport: BluetoothTransport) {
        self.device = device
        self.transport = transport
    }

    /// Initialise a session over any channel, for tests.
    init(transport: ByteChannel) {
        self.device = nil
        self.transport = transport
    }

    // MARK: Handshake

    /// Perform the Diffie–Hellman handshake.
    ///
    /// Step 1: send `hello`. The printer answers with its generator, modulus
    /// and public value. Step 2: reply with our public value plus an AES
    /// confirmation block. The printer answers `ok` and the session key is the
    /// upper-case hex text of the shared secret, NUL-padded to 16 bytes.
    ///
    /// The printer often drops the first `hello` of a connection while its
    /// serial link is still settling, so the greeting is repeated until it is
    /// answered.
    func handshake(timeout: TimeInterval = 45, helloAttempts: Int = 4) throws {
        var info: Frame.Parsed?

        for attempt in 1...helloAttempts {
            transport.write(Frame.build(command: Frame.Command.hello, body: Data("hello".utf8)))

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                guard let frame = transport.readFrame(timeout: deadline.timeIntervalSinceNow) else { break }
                guard frame.command == Frame.Command.dhInfo else { continue }
                info = frame
                break
            }

            if let info { break }
            print("  no DH parameters yet (attempt \(attempt)/\(helloAttempts)), retrying…")
        }

        guard let info else {
            throw PrinterError.timeout("printer did not send DH parameters")
        }

        let body = info.body
        guard body.count == 36 else {
            throw PrinterError.protocolViolation("expected a 36-byte DH body, got \(body.count)")
        }

        let generator = hexValue(body[0..<4])
        let modulus = hexValue(body[4..<20])
        let peerPublic = hexValue(body[20..<36])
        guard generator == 2, modulus > 4, peerPublic > 0, peerPublic < modulus else {
            throw PrinterError.protocolViolation("unexpected DH parameters")
        }

        // Fresh private value in [3, modulus - 2].
        let secret = UInt64.random(in: 3...(modulus - 2))
        let publicValue = modexp(generator, secret, modulus)
        let shared = modexp(peerPublic, secret, modulus)

        // The key is the hex TEXT of the shared secret, NUL-padded to 16 bytes —
        // not the binary value.
        var keyBytes = Array(hexString(shared).utf8)
        keyBytes.append(contentsOf: [UInt8](repeating: 0, count: 16 - keyBytes.count))
        let key = Data(keyBytes)

        var confirmation = Array(hexString(publicValue, width: 16).utf8)
        confirmation += Array(AES.ecb(key, Data(body[4..<20])))

        transport.write(Frame.build(command: Frame.Command.dhConfirm,
                                    body: Data(confirmation),
                                    sequence: 1))

        guard let result = transport.readFrame(timeout: timeout, where: { $0.command == Frame.Command.dhResult }) else {
            throw PrinterError.timeout("printer did not confirm the handshake")
        }
        let text = String(decoding: result.body, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        guard text == "ok" else {
            throw PrinterError.protocolViolation("handshake rejected: '\(text)'")
        }

        sessionKey = key
    }

    // MARK: JSON requests

    /// Send a JSON request and return the decoded reply.
    ///
    /// - Parameter method: e.g. `get-prop`, `combo-job`, `get-job-info`.
    /// - Parameter params: parameters array or object.
    func request(method: String, params: Any, timeout: TimeInterval = 60) throws -> [String: Any] {
        guard let key = sessionKey else { throw PrinterError.notHandshaked }

        requestID += 1
        let id = requestID
        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params,
            "spec-type": 1,
        ]
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let encrypted = AES.encryptPadded(key, json)

        transport.write(Frame.build(command: Frame.Command.request,
                                    body: encrypted,
                                    channel: Frame.Channel.json,
                                    sequence: 1,
                                    encrypted: true,
                                    fragments: 1,
                                    fragment: 1))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let frame = transport.readFrame(timeout: deadline.timeIntervalSinceNow) else {
                throw PrinterError.timeout("no reply to '\(method)'")
            }
            guard frame.command == Frame.Command.response,
                  frame.channel == Frame.Channel.json || frame.channel == Frame.Channel.fileTransfer
            else { continue }

            var body = frame.body
            if frame.isEncrypted {
                guard body.count % 16 == 0 else {
                    throw PrinterError.protocolViolation("encrypted payload is not block aligned")
                }
                body = AES.ecb(key, body, decrypt: true)
            }
            let text = String(decoding: body, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))

            guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw PrinterError.protocolViolation("reply was not a JSON object")
            }
            if object["method"] != nil {
                // Unsolicited notification (event.*). Keep waiting for our id.
                if let eventMethod = object["method"] as? String, eventMethod == "event.rpt_err" {
                    throw PrinterError.printerReported(object["params"] ?? "unspecified error")
                }
                continue
            }
            if (object["id"] as? Int) == id {
                if let error = object["error"] {
                    throw PrinterError.printerReported(error)
                }
                return object
            }
        }
        throw PrinterError.timeout("no matching reply for '\(method)'")
    }

    /// Convenience wrapper for `get-prop`.
    func properties(_ names: [String]) throws -> Any? {
        let reply = try request(method: "get-prop", params: names)
        return reply["result"]
    }
}

enum PrinterError: Error, CustomStringConvertible {
    case timeout(String)
    case protocolViolation(String)
    case notHandshaked
    case printerReported(Any)

    var description: String {
        switch self {
        case .timeout(let m): return "timeout: \(m)"
        case .protocolViolation(let m): return "protocol error: \(m)"
        case .notHandshaked: return "handshake required"
        case .printerReported(let detail): return "printer reported: \(detail)"
        }
    }
}

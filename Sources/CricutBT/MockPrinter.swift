import Foundation

/// An in-memory stand-in for the StickerPix.
///
/// It speaks the real protocol: it answers `hello` with Diffie–Hellman
/// parameters, verifies the client's confirmation, and answers JSON requests
/// with the same shapes the printer uses. This lets the client be exercised
/// end to end without hardware.
final class MockPrinter: ByteChannel {
    // Diffie–Hellman parameters the real printer uses.
    private let generator: UInt64 = 2
    private let modulus: UInt64 = 0xE6969D3D495BE32C
    private let secret: UInt64 = 0x0123456789ABCDEF

    private var sessionKey: Data?
    private var buffer = Data()
    private var pending = [Data]()

    /// Every JSON request the client made, for assertions.
    private(set) var requests: [(method: String, params: Any)] = []
    /// Every uploaded fragment the client sent, reassembled.
    private(set) var uploaded = Data()

    /// The file sizes the client declared in its `combo-job`, in upload order.
    private var declaredFileSizes: [Int] = []

    /// Property values returned by `get-prop`.
    ///
    /// The printer answers with a flat list, one entry per requested name.
    var properties: [String: Any] = [
        "printer-state": "20",
        "printer-sub-state": "2000",
        "printer-state-alerts": ":0:0",
        "firmware-revision": "1.0.31_0033",
        "model": "CSTP401",
        "serial-number": "MOCK-0001",
        "bt-fw_ver": "+GVER:BR8051A01B_fW_260519_r7997",
        "ribbon-info": ["0", "0", "36", "0", "0", "0"],
        "auto-off-interval": "1200",
    ]

    /// The job id handed out for the next `combo-job`.
    var assignedJobID = 30

    // MARK: ByteChannel

    @discardableResult
    func write(_ data: Data) -> Bool {
        // Handle the frame that was just sent.
        var incoming = data
        while let parsed = Frame.parse(&incoming) {
            handle(parsed)
        }
        return true
    }

    func readFrame(timeout: TimeInterval) -> Frame.Parsed? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if !pending.isEmpty {
                var frame = pending.removeFirst()
                if let parsed = Frame.parse(&frame) { return parsed }
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            Thread.sleep(forTimeInterval: min(0.005, remaining))
        }
    }

    func readFrame(timeout: TimeInterval, where predicate: (Frame.Parsed) -> Bool) -> Frame.Parsed? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let frame = readFrame(timeout: deadline.timeIntervalSinceNow) else { return nil }
            if predicate(frame) { return frame }
        }
        return nil
    }

    // MARK: Protocol handling

    private func handle(_ frame: Frame.Parsed) {
        switch (frame.channel, frame.command) {
        case (Frame.Channel.control, Frame.Command.hello):
            handleHello()
        case (Frame.Channel.control, Frame.Command.dhConfirm):
            handleConfirmation(frame)
        case (Frame.Channel.json, Frame.Command.request):
            handleJSONRequest(frame)
        case (Frame.Channel.fileTransfer, Frame.Command.request):
            handleFileFragment(frame)
        default:
            break
        }
    }

    private func handleHello() {
        // Body: generator hex, modulus hex, public value hex — 36 bytes.
        var body = Data()
        body += Array(hexString(generator).utf8) + Data([0, 0, 0])
        body += Array(hexString(modulus, width: 16).utf8)
        body += Array(hexString(modexp(generator, secret, modulus), width: 16).utf8)
        enqueue(Frame.build(command: Frame.Command.dhInfo, body: body))
    }

    private func handleConfirmation(_ frame: Frame.Parsed) {
        guard frame.body.count == 32 else { return }
        let clientPublic = hexValue(frame.body[0..<16])
        let clientConfirmation = Data(frame.body[16..<32])

        // Recompute the shared secret and the expected confirmation.
        let shared = modexp(clientPublic, secret, modulus)
        var keyBytes = Array(hexString(shared).utf8)
        keyBytes.append(contentsOf: [UInt8](repeating: 0, count: 16 - keyBytes.count))
        let key = Data(keyBytes)
        sessionKey = key

        var expected = Data()
        expected += Array(AES.ecb(key, Data(Array(hexString(modulus, width: 16).utf8))))
        if expected == clientConfirmation {
            enqueue(Frame.build(command: Frame.Command.dhResult, body: Data("ok".utf8)))
        } else {
            enqueue(Frame.build(command: Frame.Command.dhResult, body: Data("bad".utf8)))
        }
    }

    private func handleJSONRequest(_ frame: Frame.Parsed) {
        var body = frame.body
        if frame.isEncrypted, let key = sessionKey {
            body = AES.ecb(key, body, decrypt: true)
        }
        let text = String(decoding: body, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let method = object["method"] as? String ?? ""
        let params = object["params"] as Any
        requests.append((method, params))
        let id = object["id"] as? Int ?? 0

        var reply: [String: Any]
        switch method {
        case "get-prop":
            let names = params as? [String] ?? []
            reply = ["id": id, "result": names.compactMap { properties[$0] }]
        case "combo-job":
            // The declared file sizes let the mock trim the zero padding the
            // AES block padding added to the final fragment.
            declaredFileSizes = []
            if let entries = params as? [[String: Any]] {
                for entry in entries {
                    if let p = entry["params"] as? [String: Any],
                       let size = p["file-size"] as? Int {
                        declaredFileSizes.append(size)
                    }
                }
            }
            reply = ["id": id, "result": ["job-id": assignedJobID]]
        case "get-job-info":
            reply = ["id": id, "result": [["job-id": assignedJobID,
                                          "job-state": 9,
                                          "printing-page-number": 1,
                                          "copies": 1,
                                          "cut-contours": 1,
                                          "cutting-progress": 1]]]
        default:
            reply = ["id": id, "error": "unknown method \(method)"]
        }

        let encoded = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
        let encrypted = AES.encryptPadded(sessionKey ?? Data(repeating: 0, count: 16), encoded)
        enqueue(Frame.build(command: Frame.Command.response,
                            body: encrypted,
                            channel: Frame.Channel.json,
                            sequence: 1,
                            encrypted: true,
                            fragments: 1,
                            fragment: 1))
    }

    private func handleFileFragment(_ frame: Frame.Parsed) {
        var body = frame.body
        if frame.isEncrypted, let key = sessionKey {
            body = AES.ecb(key, body, decrypt: true)
        }
        // Skip the four-byte job id prefix.
        guard body.count >= 4 else { return }
        uploaded.append(body[4...])
    }
    /// The uploaded bytes with the trailing zero padding removed.
    var uploadedTrimmed: Data {
        let expected = declaredFileSizes.reduce(0, +)
        guard expected > 0, uploaded.count >= expected else { return uploaded }
        return Data(uploaded.prefix(expected))
    }

    private func enqueue(_ frame: Data) {
        pending.append(frame)
    }
}

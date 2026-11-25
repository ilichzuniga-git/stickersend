import Foundation
import IOBluetooth

/// Classic Bluetooth (RFCOMM) transport for the Cricut StickerPix.
///
/// The printer advertises a Serial Port service; the RFCOMM channel number is
/// discovered through SDP on every connection because the printer does not
/// always advertise the same channel across sessions.
final class BluetoothTransport: NSObject, IOBluetoothRFCOMMChannelDelegate, ByteChannel {
    private(set) var channel: IOBluetoothRFCOMMChannel?
    private var buffer = Data()
    private let lock = NSLock()
    private let condition = NSCondition()
    private var closed = false

    /// Bytes received but not yet consumed by a parser.
    private var pending = Data()

    // MARK: Discovery

    /// Resolve a paired printer by Bluetooth address, or auto-detect a paired
    /// Cricut StickerPix when `address` is empty.
    static func device(address: String) -> IOBluetoothDevice? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return IOBluetoothDevice(addressString: trimmed)
        }
        return autoDetectStickerPix()
    }

    /// Find a paired Cricut StickerPix Print+Cut in macOS Bluetooth devices.
    static func autoDetectStickerPix() -> IOBluetoothDevice? {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return nil }
        return paired.first { dev in
            let name = (dev.name ?? "").lowercased()
            return name.contains("stickerpix") || name.contains("cricut") || name.contains("cstp")
        }
    }

    /// Query SDP for the Serial Port service and return its RFCOMM channels.
    ///
    /// The printer advertises more than one service record, and the Serial
    /// Port channel id has been observed changing between queries, so every
    /// matching channel is returned and the caller tries them in turn.
    ///
    /// - Parameter device: the paired printer.
    /// - Returns: the channel ids found, in the order advertised.
    static func serialPortChannels(on device: IOBluetoothDevice) -> [BluetoothRFCOMMChannelID] {
        guard let records = device.services else { return [] }
        var channels: [BluetoothRFCOMMChannelID] = []
        for record in records {
            let r = record as! IOBluetoothSDPServiceRecord
            if r.matchesUUID16(0x1101) {
                var channelID: BluetoothRFCOMMChannelID = 0
                if r.getRFCOMMChannelID(&channelID) == kIOReturnSuccess,
                   !channels.contains(channelID) {
                    channels.append(channelID)
                }
            }
        }
        return channels
    }

    // MARK: Lifecycle

    /// Open an RFCOMM channel to the printer.
    ///
    /// The printer is slow to accept a second session while a previous one is
    /// still winding down, so callers should be prepared to retry.
    func open(device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID) -> IOReturn {
        var ch: IOBluetoothRFCOMMChannel? = nil
        let rc = device.openRFCOMMChannelSync(&ch, withChannelID: channelID, delegate: self)
        if rc == kIOReturnSuccess, let ch {
            channel = ch
            closed = false
        }
        return rc
    }

    /// Close the channel and drop the baseband link.
    func close(device: IOBluetoothDevice? = nil) {
        if let ch = channel {
            _ = ch.close()
            channel = nil
        }
        device?.closeConnection()
    }

    // MARK: I/O

    func write(_ data: Data) -> Bool {
        guard let ch = channel else { return false }
        var rc: IOReturn = kIOReturnSuccess
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            rc = ch.writeSync(UnsafeMutableRawPointer(mutating: raw.baseAddress!), length: UInt16(data.count))
        }
        return rc == kIOReturnSuccess
    }

    /// Wait for one complete frame.
    ///
    /// The read pumps the run loop rather than blocking on a condition,
    /// because IOBluetooth delivers channel data on the main run loop.
    ///
    /// - Parameter timeout: seconds to wait before giving up.
    /// - Returns: the parsed frame, or nil on timeout.
    func readFrame(timeout: TimeInterval) -> Frame.Parsed? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            var parsed = Frame.parse(&buffer)
            lock.unlock()
            if let parsed { return parsed }
            if closed { return nil }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(min(0.05, remaining)))
        }
    }

    /// Convenience: wait for a frame matching a predicate.
    func readFrame(timeout: TimeInterval, where predicate: (Frame.Parsed) -> Bool) -> Frame.Parsed? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let frame = readFrame(timeout: deadline.timeIntervalSinceNow) else { return nil }
            if predicate(frame) { return frame }
        }
        return nil
    }
    // MARK: IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel,
                           data dataPointer: UnsafeMutableRawPointer,
                           length dataLength: Int) {
        let chunk = Data(bytes: dataPointer, count: dataLength)
        lock.lock()
        buffer.append(chunk)
        lock.unlock()
        condition.signal()
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel, status error: IOReturn) {}

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel) {
        closed = true
        condition.signal()
    }
}

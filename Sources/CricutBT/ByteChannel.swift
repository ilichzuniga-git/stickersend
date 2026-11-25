import Foundation

/// A byte-oriented channel to the printer.
///
/// The real implementation speaks RFCOMM over Bluetooth; the mock in
/// `MockPrinter` implements the same interface in memory so the protocol can
/// be exercised without hardware.
protocol ByteChannel: AnyObject {
    /// Send one frame.
    @discardableResult
    func write(_ data: Data) -> Bool
    /// Wait for one complete frame.
    func readFrame(timeout: TimeInterval) -> Frame.Parsed?
    /// Wait for one complete frame matching a predicate.
    func readFrame(timeout: TimeInterval, where predicate: (Frame.Parsed) -> Bool) -> Frame.Parsed?
}

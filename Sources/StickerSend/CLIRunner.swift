import Foundation

/// Runs the `cricut-bt` command-line tool and streams its output line by line.
///
/// The GUI deliberately shells out instead of linking the protocol code: the
/// CLI is the path that ran jobs 19 and 20 on real hardware, and IOBluetooth
/// delivers RFCOMM data on the run loop of the thread that opened the channel,
/// which the CLI already handles.
final class CLIRunner {
    private var process: Process?

    var isRunning: Bool { process?.isRunning ?? false }

    /// The `cricut-bt` binary: next to this app's executable (works for both
    /// `.build/release/` and a `StickerSend.app/Contents/MacOS/` bundle).
    static func defaultBinary() -> URL? {
        let candidates: [URL?] = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("cricut-bt"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/stickers/cricut-bt/.build/release/cricut-bt"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Start the tool. `onLine` and `onExit` are called on the main queue.
    func run(binary: URL,
             arguments: [String],
             onLine: @escaping (String) -> Void,
             onExit: @escaping (Int32) -> Void) throws {
        let p = Process()
        p.executableURL = binary
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        var pending = Data()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                DispatchQueue.main.async { onLine(line) }
            }
        }
        p.terminationHandler = { proc in
            handle.readabilityHandler = nil
            let rest = handle.readDataToEndOfFile()
            let tail = String(decoding: pending + rest, as: UTF8.self)
            DispatchQueue.main.async {
                for line in tail.split(separator: "\n") { onLine(String(line)) }
                onExit(proc.terminationStatus)
            }
        }
        try p.run()
        process = p
    }

    func terminate() {
        process?.terminate()
    }
}

import Foundation
import CryptoKit

/// The two files a print-and-cut job needs: the printed JPEG and the PLT cut
/// file, plus the metadata needed to submit them to the printer.
struct PrintSheet {
    /// The print image, 1200 × 2100 JPEG.
    var image: Data
    /// The cut file, ASCII PLT.
    var cut: Data
    /// Number of outlines in the cut file.
    var cutCount: Int
    /// A short name for the job.
    var name: String

    /// Maximum bytes in one upload fragment.
    static let chunkBytes = 892
    /// The printer's ceiling on copies per job.
    static let maxCopies = 36

    /// Upload order: cut data first, then the print image.
    var transferData: Data { cut + image }

    /// Number of fragments the upload will use.
    var fragmentCount: Int {
        (transferData.count + Self.chunkBytes - 1) / Self.chunkBytes
    }

    /// Build the `combo-job` parameters for the requested number of copies.
    func parameters(copies: Int = 1) -> [[String: Any]] {
        precondition((1...Self.maxCopies).contains(copies))
        // The document name is derived from the payload so that an unchanged
        // sheet keeps the same name across runs.
        let digest = SHA256.hash(data: transferData).prefix(6).map { String(format: "%02x", $0) }.joined()
        let stem = "sheet_\(digest)"

        return [
            [
                "id": 0,
                "method": "print-job",
                "params": [
                    "copies": copies,
                    "document-format": 9,      // JPEG
                    "document-name": "\(stem).jpg",
                    "filePath": "\(stem).jpg",
                    "file-size": image.count,
                    "job-type": 600,           // print and cut
                    "media-size": 5013,
                    "media-type": 2030,
                ],
                "spec-type": 0,
            ],
            [
                "id": 0,
                "method": "cut-job",
                "params": [
                    "copies": copies,
                    "document-format": 18,      // PLT text
                    "document-name": "\(stem).plt",
                    "filePath": "\(stem).plt",
                    "file-size": cut.count,
                    "job-type": 600,
                    "media-size": 5013,
                    "media-type": 2030,
                ],
                "spec-type": 0,
            ],
        ]
    }

    /// Build the encrypted upload fragments for an assigned job id.
    ///
    /// Each fragment carries the job id as a four-byte little-endian integer
    /// ahead of the payload, then is encrypted and sent on the file-transfer
    /// channel with the file payload type.
    func uploadFrames(key: Data, jobID: Int) -> [Data] {
        let data = transferData
        let count = fragmentCount
        var frames: [Data] = []
        frames.reserveCapacity(count)

        var offset = 0
        var index = 1
        while offset < data.count {
            let end = min(offset + Self.chunkBytes, data.count)
            var body = Data()
            var jobIDLE = UInt32(jobID).littleEndian
            withUnsafeBytes(of: &jobIDLE) { body.append(contentsOf: $0) }
            body.append(data[offset..<end])

            frames.append(Frame.build(command: Frame.Command.request,
                                      body: AES.encryptPadded(key, body),
                                      channel: Frame.Channel.fileTransfer,
                                      sequence: UInt32(index),
                                      encrypted: true,
                                      fragments: UInt16(count),
                                      fragment: UInt16(index),
                                      fileTransfer: true,
                                      payloadType: Frame.PayloadType.file))
            offset = end
            index += 1
        }
        return frames
    }
}

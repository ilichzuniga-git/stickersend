import Foundation

/// Submit a print-and-cut job and follow the printer's progress.
enum JobRunner {

    /// Printer-reported job states.
    enum JobState: Int {
        case waiting = 1, started = 2, inProgress = 3, unavailable = 4
        case interrupted = 5, terminating = 6, failed = 7, cancelled = 8, completed = 9

        var isTerminal: Bool { self == .failed || self == .cancelled || self == .completed }
        var label: String {
            switch self {
            case .waiting: return "Waiting"
            case .started: return "Started"
            case .inProgress: return "In progress"
            case .unavailable: return "Temporarily unavailable"
            case .interrupted: return "Interrupted"
            case .terminating: return "Terminating"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            case .completed: return "Completed"
            }
        }
    }

    /// Sub-states describing what the printer is doing.
    static let stages: [Int: String] = [
        2000: "Idle/starting",
        3015: "Preparing",
        3016: "Decoding",
        3017: "Feeding paper",
        3018: "Printing yellow",
        3019: "Printing magenta",
        3020: "Printing cyan",
        3021: "Protective layer",
        3025: "Returning home",
        3028: "Feeding for cutting",
        3029: "Finding origin",
        3030: "Cutting",
        3031: "Retracting blade",
    ]

    /// Submit the job, upload its files, and monitor until it finishes.
    ///
    /// - Parameters:
    ///   - copies: how many identical sheets to print.
    ///   - progress: called with a status line for each update.
    static func submit(session: PrinterSession,
                       sheet: PrintSheet,
                       copies: Int = 1,
                       pollInterval: TimeInterval = 2,
                       maxWait: TimeInterval = 900,
                       progress: (String) -> Void) throws -> [String: Any] {
        guard let key = session.sessionKey else { throw PrinterError.notHandshaked }

        // Refuse to start a job unless the printer is idle.
        let state = try session.properties(["printer-state"])
        if let list = state as? [Any], let first = list.first, "\(first)" != "20" {
            throw PrinterError.printerReported("printer is not idle (state \(first))")
        }

        progress("submitting job (\(copies) cop\(copies == 1 ? "y" : "ies"))…")
        let reply = try session.request(method: "combo-job", params: sheet.parameters(copies: copies))
        guard let result = reply["result"] as? [String: Any],
              let jobID = result["job-id"] as? Int,
              jobID > 0 else {
            throw PrinterError.protocolViolation("no job id in the submission reply: \(reply)")
        }
        progress("printer accepted job \(jobID)")

        // Upload the cut file and the print image.
        let frames = sheet.uploadFrames(key: key, jobID: jobID)
        for (index, frame) in frames.enumerated() {
            guard session.transport.write(frame) else {
                throw PrinterError.protocolViolation("upload write failed at fragment \(index + 1)")
            }
            if index == 0 || index % 25 == 0 || index == frames.count - 1 {
                progress("uploading \(index + 1)/\(frames.count) fragments…")
            }
            // Pacing keeps the transfer close to the printer's own ingest rate.
            Thread.sleep(forTimeInterval: 0.01)
        }
        progress("upload complete (\(frames.count) fragments)")

        return try monitor(session: session,
                           jobID: jobID,
                           pollInterval: pollInterval,
                           maxWait: maxWait,
                           progress: progress)
    }

    /// Poll the printer until the job reaches a terminal state.
    static func monitor(session: PrinterSession,
                        jobID: Int,
                        pollInterval: TimeInterval = 2,
                        maxWait: TimeInterval = 900,
                        progress: (String) -> Void) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(maxWait)

        while Date() < deadline {
            let reply = try session.request(method: "get-job-info", params: ["job-id": jobID])
            guard let rows = reply["result"] as? [[String: Any]],
                  let info = rows.first(where: { ($0["job-id"] as? Int) == jobID }) else {
                throw PrinterError.protocolViolation("no status for job \(jobID)")
            }

            if let raw = info["job-state"] as? Int, let state = JobState(rawValue: raw) {
                let subState = (try? session.properties(["printer-sub-state"])) as? [Any]
                let stageName: String
                // The printer reports the sub-state as a decimal string, so it
                // has to be read as text and then converted.
                var code: Int?
                if let list = subState, let first = list.first {
                    code = (first as? String).flatMap { Int($0) } ?? (first as? Int)
                }
                if let code {
                    stageName = stages[code] ?? "Stage \(code)"
                } else {
                    stageName = "Working"
                }
                let contours = info["cut-contours"].map { "\($0)" } ?? "?"
                progress("job \(jobID): \(state.label) — \(stageName) (contours \(contours))")

                if state.isTerminal {
                    return info
                }
            }

            Thread.sleep(forTimeInterval: pollInterval)
        }

        throw PrinterError.timeout("stopped monitoring job \(jobID); completion is unknown")
    }
}

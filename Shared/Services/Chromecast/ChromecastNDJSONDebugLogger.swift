//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// DEBUG-only logger that writes NDJSON lines to Cursor's debug log file.
enum ChromecastNDJSONDebugLogger {

    private static let sessionId = "b3229f"
    private static let logPath = "/Users/ayman/Documents/GitHub/PlexClone/.cursor/debug-b3229f.log"
    private static let writeQueue = DispatchQueue(label: "ChromecastNDJSONDebugLogger.writeQueue")
    private static var hostFileWriteDisabled = false
    private static var didPrintHostFileWriteDisableReason = false

    static func log(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:],
        runId: String = "debug_pre"
    ) {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let logId = "cast_debug_\(timestamp)_\(hypothesisId)"

        // Keep payload JSON-serializable and avoid secrets/PII.
        let payload: [String: Any] = [
            "id": logId,
            "sessionId": sessionId,
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": timestamp
        ]

        // Always print a breadcrumb so we can verify instrumentation hits.
        // This is our primary evidence path if host-path file writes fail on the iOS runtime.
        let dataDebug: String = (try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"
        print("[ChromecastNDJSONDebugLogger] \(timestamp) \(hypothesisId) @ \(location) - \(message) data=\(dataDebug)")

        guard JSONSerialization.isValidJSONObject(payload),
              let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonLine = String(data: jsonData, encoding: .utf8)
        else { return }

        let lineData = (jsonLine + "\n").data(using: .utf8) ?? Data()

        // Best-effort logging:
        // 1) Console (always works)
        // 2) Host file write (may fail on-device sandbox)
        // 3) (disabled) Ingest endpoint fallback
        writeQueue.sync {
            if hostFileWriteDisabled { return }

            var wroteToFile = false

            do {
                // Create file on first write (we may have deleted it before this debug run).
                if !FileManager.default.fileExists(atPath: logPath) {
                    FileManager.default.createFile(atPath: logPath, contents: nil)
                }

                guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) else {
                    throw NSError(
                        domain: "ChromecastNDJSONDebugLogger.fileOpen",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to open file handle"]
                    )
                }
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(lineData)
                wroteToFile = true
            } catch {
                hostFileWriteDisabled = true
                if !didPrintHostFileWriteDisableReason {
                    print("[ChromecastNDJSONDebugLogger] Host file writes disabled (first failure): \(error)")
                    didPrintHostFileWriteDisableReason = true
                }
            }
        }
    }
}

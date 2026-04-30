import Foundation

/// When enabled (`Settings → Record motion debug log`), writes NDJSON to Documents/debug-b248b4.ndjson
/// and optionally POSTs to the ingest URL (Simulator localhost or Mac LAN IP from Walk screen).
enum AgentDebugLog {
    /// Bind Toggle / `@AppStorage` to this key so UI stays in sync with emit guard.
    static let enabledKey = "gaitCoachAgentLogEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    private static let logFileName = "debug-b248b4.ndjson"
    private static let ingestPort = 7263
    private static let ingestPath = "/ingest/3f86589e-97df-4e09-8adf-0214760e5668"

    private static func resolvedIngestURLString() -> String {
        let raw = UserDefaults.standard.string(forKey: "debugIngestHost")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = raw.isEmpty ? "127.0.0.1" : raw
        return "http://\(host):\(ingestPort)\(ingestPath)"
    }

    private static func ingestRequestURL() -> URL? {
        URL(string: resolvedIngestURLString())
    }

    /// Walk → CALIBRATION when logging is on.
    static func resolvedIngestURLStringForUI() -> String {
        resolvedIngestURLString()
    }

    private static var lastIngestFailLogAt = Date.distantPast

    static func emit(hypothesisId: String, location: String, message: String, data: [String: Any], runId: String = "pre-fix") {
        guard isEnabled else { return }
        let payload: [String: Any] = [
            "sessionId": "b248b4",
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "runId": runId,
            "data": data,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: body, encoding: .utf8) else { return }

        print("AGENT_DBG_NDJSON \(line)")

        appendDocuments(line + "\n")

        guard let url = ingestRequestURL() else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("b248b4", forHTTPHeaderField: "X-Debug-Session-Id")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { _, resp, err in
            guard let err else {
                if let h = resp as? HTTPURLResponse, h.statusCode >= 300 {
                    let now = Date()
                    guard now.timeIntervalSince(lastIngestFailLogAt) > 2 else { return }
                    lastIngestFailLogAt = now
                    print("AGENT_DBG_INGEST_HTTP \(h.statusCode)")
                }
                return
            }
            let now = Date()
            guard now.timeIntervalSince(lastIngestFailLogAt) > 2 else { return }
            lastIngestFailLogAt = now
            print("AGENT_DBG_INGEST_FAIL \(err.localizedDescription)")
        }.resume()
    }

    private static func appendDocuments(_ string: String) {
        guard let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = doc.appendingPathComponent(logFileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        if let data = string.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}

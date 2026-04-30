import Foundation
import SwiftUI

enum DiagnosticsExporter {
    static func csv(for sessions: [SessionSummary]) -> String {
        var out = "date,steps,cadenceSPM,mlSwayRMS,avgStepTime,cvStepTime,asymStepTimePct,distanceM,avgSpeedMps,tags\n"
        let df = ISO8601DateFormatter()
        for s in sessions {
            let date = df.string(from: s.date)
            let tags = s.tags.joined(separator: "|")
            let dist = s.distanceM.map { String(format: "%.2f", $0) } ?? ""
            let spd = s.avgSpeedMps.map { String(format: "%.4f", $0) } ?? ""
            out += "\(date),\(s.steps),\(s.cadenceSPM),\(s.mlSwayRMS),\(s.avgStepTime),\(s.cvStepTime),\(s.asymStepTimePct),\(dist),\(spd),\(tags)\n"
        }
        return out
    }
}

struct DiagnosticsExportButton: View {
    let sessions: [SessionSummary]

    var body: some View {
        let csv = DiagnosticsExporter.csv(for: sessions)
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("gaitcoach_export.csv")
        // write once when the view appears
        _ = try? csv.data(using: .utf8)?.write(to: tmpURL, options: .atomic)

        return ShareLink(item: tmpURL, preview: .init("gaitcoach_export.csv"))
            .buttonStyle(.bordered)
    }
}

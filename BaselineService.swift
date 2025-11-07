import Foundation

/// Computes baselines and deltas for HealthKit metrics.
/// Keeps the math out of the view and HealthKit manager.
struct BaselineService {

    /// Compute a simple mean baseline over provided values.
    /// - For percent-like metrics, values are in fraction form already (e.g., 0.12 = 12%).
    static func meanBaseline(values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sum = values.reduce(0, +)
        return sum / Double(values.count)
    }

    /// Format a delta between today's value and baseline:
    /// - Percent-like metrics: show **percentage points** (e.g., +1.2 pp)
    /// - Others: show **relative %** (e.g., +4.5%)
    static func formattedDelta(today: Double, baseline: Double, isPercentLike: Bool) -> String {
        if isPercentLike {
            // Convert fraction -> percentage points
            let deltaPP = (today - baseline) * 100.0
            let sign = deltaPP >= 0 ? "+" : ""
            return "\(sign)\(String(format: "%.1f", deltaPP)) pp vs 30d"
        } else {
            // Relative %
            guard baseline != 0 else { return "—" }
            let rel = ((today - baseline) / baseline) * 100.0
            let sign = rel >= 0 ? "+" : ""
            return "\(sign)\(String(format: "%.1f", rel))% vs 30d"
        }
    }

    /// Optional arrow / trend glyph for quick glance.
    static func trendArrow(today: Double, baseline: Double, isPercentLike: Bool) -> String {
        // For asymmetry/double-support, lower is generally better → invert arrow logic if desired.
        // For now we simply show direction of change.
        let delta = today - baseline
        if abs(delta) < 0.0001 { return "→" }
        return delta > 0 ? "↑" : "↓"
    }
}


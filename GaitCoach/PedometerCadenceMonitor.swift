import CoreMotion
import Foundation

/// Hints fused into `LocomotionFusion` when the phone is handheld (Apple stride-independent signals preferred).
struct HandheldPedFusionHint: Sendable {
    /// Speed from `averageActivePace` / `currentPace` and/or cumulative distance slope (m/s).
    var directSpeedMps: Double?
    /// Fallback: cadence in steps/min when pace fields are unavailable.
    var cadenceSPM: Double?

    var hasSignal: Bool {
        if let v = directSpeedMps, v > 0.08 { return true }
        if let c = cadenceSPM, c >= 26 { return true }
        return false
    }
}

/// Builds handheld fusion hints from `CMPedometer` live updates **and** optional periodic queries (same serial queue).
final class PedometerCadenceMonitor {
    private let ped = CMPedometer()

    private var lastSteps: Int = 0
    private var lastDate: Date?

    private var lastDistanceM: Double?
    private var lastDistanceDate: Date?

    func start(from startDate: Date, targetQueue: OperationQueue, handler: @escaping (HandheldPedFusionHint) -> Void) {
        stop()
        resetBaselines()
        guard CMPedometer.isStepCountingAvailable() else { return }

        ped.startUpdates(from: startDate) { [weak self] data, error in
            guard error == nil, let self, let data else { return }
            targetQueue.addOperation {
                let hint = self.buildHint(from: data)
                guard hint.hasSignal else { return }
                handler(hint)
            }
        }
    }

    /// Merge cumulative snapshot (from `queryPedometerData`) using the same distance/step baselines as live updates.
    func hintFromQuerySnapshot(_ data: CMPedometerData) -> HandheldPedFusionHint {
        buildHint(from: data)
    }

    func stop() {
        ped.stopUpdates()
    }

    func queryAccumulated(from start: Date, to end: Date, handler: @escaping (CMPedometerData?, Error?) -> Void) {
        ped.queryPedometerData(from: start, to: end, withHandler: handler)
    }

    func resetBaselines() {
        lastSteps = 0
        lastDate = nil
        lastDistanceM = nil
        lastDistanceDate = nil
    }

    private func buildHint(from data: CMPedometerData) -> HandheldPedFusionHint {
        let anchor = data.endDate

        let directFromPace = speedFromPaceFields(data)
        let directFromDist = speedFromDistanceDelta(data: data, anchor: anchor)

        let direct: Double?
        switch (directFromPace, directFromDist) {
        case let (p?, d?):
            direct = 0.58 * p + 0.42 * d
        case let (p?, nil):
            direct = p
        case let (nil, d?):
            direct = d
        default:
            direct = nil
        }

        let cadence = resolvedCadenceSPM(data: data, anchor: anchor)

        return HandheldPedFusionHint(directSpeedMps: direct, cadenceSPM: cadence)
    }

    /// Pace fields are **seconds per meter** → speed = 1 / pace (m/s).
    private func speedFromPaceFields(_ data: CMPedometerData) -> Double? {
        func fromPace(_ num: NSNumber?) -> Double? {
            guard let num else { return nil }
            let pace = num.doubleValue
            guard pace > 0.28, pace < 6.5 else { return nil }
            let v = 1.0 / pace
            guard v > 0.22, v < 8.5 else { return nil }
            return v
        }
        return fromPace(data.averageActivePace) ?? fromPace(data.currentPace)
    }

    private func speedFromDistanceDelta(data: CMPedometerData, anchor: Date) -> Double? {
        guard let distNum = data.distance else { return nil }
        let dist = distNum.doubleValue
        guard dist.isFinite, dist > 2 else { return nil }

        guard let prevM = lastDistanceM, let prevT = lastDistanceDate else {
            lastDistanceM = dist
            lastDistanceDate = anchor
            return nil
        }

        let dd = dist - prevM
        let dt = anchor.timeIntervalSince(prevT)
        lastDistanceM = dist
        lastDistanceDate = anchor

        guard dt > 0.35, dd > 0.35 else { return nil }
        let v = dd / dt
        guard v > 0.22, v < 6.0 else { return nil }
        return v
    }

    private func resolvedCadenceSPM(data: CMPedometerData, anchor: Date) -> Double? {
        if let c = data.currentCadence?.doubleValue, c > 0 {
            let spm = c * 60.0
            if spm >= 26 && spm <= 220 {
                lastSteps = data.numberOfSteps.intValue
                lastDate = anchor
                return spm
            }
        }

        let steps = data.numberOfSteps.intValue

        guard let prevT = lastDate else {
            lastSteps = steps
            lastDate = anchor
            return nil
        }

        let dt = anchor.timeIntervalSince(prevT)
        let ds = steps - lastSteps
        lastSteps = steps
        lastDate = anchor

        guard dt > 0.18, ds >= 1 else { return nil }
        let spm = Double(ds) / dt * 60.0
        guard spm >= 26 && spm <= 220 else { return nil }
        return spm
    }
}

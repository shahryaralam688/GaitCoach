import Foundation
import simd

/// Step picking tuned for handheld arm swing vs pocket carry using HP accel + adaptive refractory.
final class HandheldStepDetector {

    private struct Sample {
        let t: TimeInterval
        let fwd: Double
        let ml: Double
        let up: Double
        let magMs2: Double
        let gyroMag: Double
        let score: Double
    }

    private var samples: [Sample] = []
    private let capacity = 240

    private var lastStepTS: TimeInterval = -1_000
    private var fwdPrev: Double = 0

    func reset() {
        samples.removeAll()
        lastStepTS = -1_000
        fwdPrev = 0
    }

    /// Returns peak acceleration magnitude (m/s²) at detected strike when a step fires.
    func analyze(
        timestamp: TimeInterval,
        fwd: Double,
        ml: Double,
        up: Double,
        gyro: simd_double3,
        carryMode: CarryMode,
        calibrationOK: Bool,
        cadenceHintSPM: Double
    ) -> Double? {

        let magMs2 = sqrt(fwd * fwd + ml * ml + up * up)
        let gyroMag = simd_length(gyro)

        let hpUp: Double
        let hpFwd: Double
        if samples.count >= 18 {
            hpUp = highPassLast(values: samples.map(\.up), current: up, window: 18)
            hpFwd = highPassLast(values: samples.map(\.fwd), current: fwd, window: 18)
        } else {
            hpUp = up
            hpFwd = fwd
        }

        let scoreNow = score(hpUp: hpUp, hpFwd: hpFwd, carryMode: carryMode)
        samples.append(Sample(t: timestamp, fwd: fwd, ml: ml, up: up, magMs2: magMs2, gyroMag: gyroMag, score: scoreNow))
        trim()

        guard samples.count >= 35 else {
            return legacyPocketIfNeeded(fwd: fwd, calibrationOK: calibrationOK, carryMode: carryMode, timestamp: timestamp, magMs2: magMs2)
        }

        let minGapLower = max(0.26, min(0.52, 55.0 / max(cadenceHintSPM, 65)))
        guard timestamp - lastStepTS >= minGapLower else { return nil }

        let hist = samples.map(\.score)
        let med = median(hist.suffix(140))
        let mad = medianAbsoluteDeviation(hist.suffix(140), median: med)
        let thresh = med + (carryMode == .handheld ? 4.2 : 3.4) * mad

        let iLast = samples.count - 1
        let s0 = samples[iLast].score
        guard s0 > thresh, iLast >= 1 else {
            return legacyPocketIfNeeded(fwd: fwd, calibrationOK: calibrationOK, carryMode: carryMode, timestamp: timestamp, magMs2: magMs2)
        }

        let sPrev = samples[iLast - 1].score
        guard s0 >= sPrev else {
            return legacyPocketIfNeeded(fwd: fwd, calibrationOK: calibrationOK, carryMode: carryMode, timestamp: timestamp, magMs2: magMs2)
        }

        lastStepTS = timestamp
        fwdPrev = fwd

        let peakWin = samples.suffix(28).map(\.magMs2).max() ?? magMs2
        _ = gyroMag
        return max(peakWin, magMs2)
    }

    private func trim() {
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    private func score(hpUp: Double, hpFwd: Double, carryMode: CarryMode) -> Double {
        switch carryMode {
        case .handheld: return hpUp + 0.12 * hpFwd
        case .pocket: return 0.55 * hpUp + 0.45 * hpFwd
        }
    }

    private func legacyPocketIfNeeded(
        fwd: Double,
        calibrationOK: Bool,
        carryMode: CarryMode,
        timestamp: TimeInterval,
        magMs2: Double
    ) -> Double? {
        if carryMode != .pocket {
            fwdPrev = fwd
            return nil
        }
        let thr = 0.88
        guard calibrationOK else {
            fwdPrev = fwd
            return nil
        }
        if fwdPrev <= thr, fwd > thr, timestamp - lastStepTS > 0.28 {
            lastStepTS = timestamp
            fwdPrev = fwd
            return magMs2
        }
        fwdPrev = fwd
        return nil
    }

    private func highPassLast(values: [Double], current: Double, window: Int) -> Double {
        guard window >= 3 else { return current }
        let take = min(values.count, window - 1)
        guard take > 0 else { return current }
        let tail = values.suffix(take)
        let mean = tail.reduce(0, +) / Double(tail.count)
        return current - mean
    }

    private func median(_ slice: ArraySlice<Double>) -> Double {
        let sorted = slice.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private func medianAbsoluteDeviation(_ slice: ArraySlice<Double>, median m: Double) -> Double {
        guard !slice.isEmpty else { return 0 }
        let dev = slice.map { abs($0 - m) }.sorted()
        let mid = dev.count / 2
        let medDev = dev.count.isMultiple(of: 2) ? (dev[mid - 1] + dev[mid]) / 2 : dev[mid]
        return max(medDev * 1.4826, 0.02)
    }
}

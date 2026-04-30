import Foundation

/// Values copied from settings for motion-queue fusion math (avoid reading ObservableObject off-thread).
struct LocomotionIntegrationParams: Sendable {
    var locomotionSurface: LocomotionSurface
    var treadmillUsesBeltSpeed: Bool
    var treadmillBeltMps: Double
    /// Walk vs Run session mode — affects step pacing gates and decay (motion layer reads from settings).
    var paceSessionKind: PaceSessionKind = .walk
    /// Pocket vs handheld — handheld uses slower speed decay + optional CMPedometer cadence blend.
    var carryMode: CarryMode = .handheld
}

/// Pure math helpers (testable without device motion).
enum LocomotionMath {
    /// Converts user-acceleration magnitude (m/s²) to approximate g-units for Weinberg exponent.
    static func peakAccelG(fromMagnitudeMs2 m: Double) -> Double {
        max(0.05, m / 9.80665)
    }

    /// Weinberg-style stride length (m): `K * a_peak^0.25`, blended with anthropometric fallback.
    static func strideLengthMeters(peakAccelG: Double, weinbergK: Double?, heightCm: Int) -> Double {
        let h = max(130, min(220, heightCm))
        let heightM = Double(h) / 100.0
        let anthropometric = max(0.35, min(1.65, 0.415 * heightM))

        guard peakAccelG > 0.06, let K = weinbergK, K > 0 else {
            return anthropometric
        }
        let w = K * pow(peakAccelG, 0.25)
        return max(0.32, min(1.75, (w + anthropometric) / 2))
    }

    /// Derive Weinberg constant K from a known-distance calibration walk.
    /// - Parameters:
    ///   - knownDistanceM: Measured distance (m).
    ///   - steps: Steps observed over that distance.
    ///   - medianPeakG: Typical peak acceleration in g-units during those steps.
    static func estimateWeinbergK(knownDistanceM: Double, steps: Int, medianPeakG: Double) -> Double? {
        guard knownDistanceM > 1, steps >= 10, medianPeakG > 0.08 else { return nil }
        let avgStride = knownDistanceM / Double(steps)
        return avgStride / pow(medianPeakG, 0.25)
    }
}

/// Scalar telemetry without copying the planar polyline (safe to call every motion tick).
struct LocomotionTelemetrySnapshot: Sendable {
    var distanceM: Double
    var speedMps: Double
    var headingDeg: Double
    var planarXM: Double
    var planarYM: Double
}

/// Distance, speed, heading fusion and 2D step-based dead reckoning (no GPS).
///
/// Indoor magnetometer-aided yaw can be biased near metal/electronics; geometric loop closure is not guaranteed.
final class LocomotionFusion {

    private let lock = NSLock()

    private var distanceM: Double = 0
    private var speedMps: Double = 0
    private var headingDeg: Double = 0

    private var speedEMA: Double = 0
    private let speedAlpha = 0.18

    private var planarXM: Double = 0
    private var planarYM: Double = 0
    /// Endpoints after each planar step (includes origin at reset).
    private var planarPath: [PlanarTrackPoint] = []

    func telemetrySnapshot() -> LocomotionTelemetrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return LocomotionTelemetrySnapshot(
            distanceM: distanceM,
            speedMps: speedMps,
            headingDeg: headingDeg,
            planarXM: planarXM,
            planarYM: planarYM
        )
    }

    func trackSnapshot() -> [PlanarTrackPoint] {
        lock.lock()
        defer { lock.unlock() }
        return planarPath
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        distanceM = 0
        speedMps = 0
        headingDeg = 0
        speedEMA = 0
        planarXM = 0
        planarYM = 0
        planarPath = [PlanarTrackPoint(xM: 0, yM: 0)]
    }

    func ingestHeading(yawRadians: Double) {
        lock.lock()
        defer { lock.unlock() }
        headingDeg = yawRadians * 180.0 / .pi
    }

    /// Per IMU tick: treadmill belt integrates distance & speed; otherwise decay inferred walk speed.
    /// Important: do **not** use `cadence × stride` every tick — handheld jitter yields fake cadence while
    /// stationary (~4–6 km/h). Live pace comes from `ingestWalkStepSpeed` at real step intervals.
    func ingestMotionTick(dt: TimeInterval, params: LocomotionIntegrationParams) {
        lock.lock()
        defer { lock.unlock() }

        guard dt > 0, dt < 1.5 else { return }

        let treadmill = params.locomotionSurface == .treadmill
        let belt = params.treadmillUsesBeltSpeed

        if treadmill && belt {
            distanceM += params.treadmillBeltMps * dt
            let instSpeed = params.treadmillBeltMps
            speedEMA = speedEMA == 0 ? instSpeed : (speedAlpha * instSpeed + (1 - speedAlpha) * speedEMA)
            speedMps = speedEMA
            return
        }

        // Handheld “looking at screen” has weaker IMU strikes — decay slower so CMPedometer cadence can sustain pace.
        let tau: Double
        switch (params.paceSessionKind, params.carryMode) {
        case (.run, .handheld): tau = 2.35
        case (.run, _): tau = 2.05
        case (_, .handheld): tau = 2.65
        default: tau = 1.45
        }
        speedEMA *= exp(-dt / tau)
        if speedEMA < 0.035 { speedEMA = 0 }
        speedMps = speedEMA
    }

    /// Pace from Apple-estimated cadence × stride (handheld viewing — complements sporadic accel strikes).
    func ingestCadenceBackedSpeed(strideLengthM: Double, cadenceSPM: Double, paceKind: PaceSessionKind) {
        lock.lock()
        defer { lock.unlock() }
        let stride = max(0.30, min(2.0, strideLengthM))
        let minCad = paceKind == .run ? 78.0 : 36.0
        let maxCad = paceKind == .run ? 215.0 : 178.0
        guard cadenceSPM >= minCad, cadenceSPM <= maxCad else { return }

        let stepsPerSec = cadenceSPM / 60.0
        let maxInst = paceKind == .run ? 7.2 : 5.3
        let instSpeed = min(maxInst, stride * stepsPerSec)
        let cadAlpha = 0.10
        speedEMA = speedEMA == 0 ? instSpeed : (cadAlpha * instSpeed + (1 - cadAlpha) * speedEMA)
        speedMps = speedEMA
    }

    /// Update pace from time between consecutive strikes (seconds) and stride length (meters).
    /// Uses capped step period so long gaps at turns still refresh pace (shuttle / line walks).
    func ingestWalkStepSpeed(strideLengthM: Double, stepPeriod: TimeInterval, paceKind: PaceSessionKind) {
        lock.lock()
        defer { lock.unlock() }
        let minPeriod = paceKind == .run ? 0.165 : 0.22
        let maxInst = paceKind == .run ? 7.2 : 4.8
        guard stepPeriod > minPeriod, stepPeriod < 4.2, strideLengthM > 0.2 else { return }
        let instSpeed = min(maxInst, strideLengthM / stepPeriod)
        speedEMA = speedEMA == 0 ? instSpeed : (speedAlpha * instSpeed + (1 - speedAlpha) * speedEMA)
        speedMps = speedEMA
    }

    func ingestStepStride(strideLengthM: Double, params: LocomotionIntegrationParams) {
        lock.lock()
        defer { lock.unlock() }
        let treadmill = params.locomotionSurface == .treadmill
        let belt = params.treadmillUsesBeltSpeed
        if treadmill && belt { return }
        distanceM += strideLengthM
    }

    /// Advance 2D pose by one stride along magnetometer-aided yaw + user calibration offset.
    ///
    /// Disabled for all **treadmill** sessions (zero net displacement); use scalar belt/distance only.
    /// Indoor magnetic yaw can drift; loops will not close like survey-grade GPS.
    func ingestStepPlanar(
        strideLengthM: Double,
        yawRadians: Double,
        headingOffsetRad: Double,
        params: LocomotionIntegrationParams
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard strideLengthM > 0.15 else { return }
        if params.locomotionSurface == .treadmill { return }

        let θ = PedestrianPlanarMath.wrapPi(yawRadians + headingOffsetRad)
        let d = PedestrianPlanarMath.deltaXY(strideMeters: strideLengthM, headingRad: θ)
        planarXM += d.dx
        planarYM += d.dy
        planarPath.append(PlanarTrackPoint(xM: planarXM, yM: planarYM))
        if planarPath.count > 12_000 {
            planarPath.removeFirst(planarPath.count - 12_000)
        }
    }
}

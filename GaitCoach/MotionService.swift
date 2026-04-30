import Foundation
import Combine
import CoreMotion
import simd

// MARK: - Public surface other code uses

protocol MotionServiceType: AnyObject, ObservableObject {
    var stepCount: Int { get }          // cumulative steps (resets on start)
    var cadenceSPM: Double { get }      // steps per minute
    var mlSwayRMS: Double { get }       // ML sway proxy (RMS accel, body frame)
    var tiltDeg: Double { get }         // slow body tilt magnitude (degrees)
    var status: MotionStatus { get }
    var stepEvent: AnyPublisher<(Date, Double), Never> { get }  // (timestamp, ML-at-step)
    var bodySample: (fwd: Double, ml: Double, up: Double) { get }

    /// True only if we have a stored transform **and** its quality is good.
    var calibrationOK: Bool { get }

    /// Locomotion fusion (no GPS).
    var distanceM: Double { get }
    var speedMps: Double { get }
    /// Heading from magnetometer-aided attitude when available (degrees).
    var headingDeg: Double { get }
    /// Horizontal planar trace from step dead reckoning (meters).
    var trackPlanarPoints: [PlanarTrackPoint] { get }
    var planarXM: Double { get }
    var planarYM: Double { get }
    /// Peak \|userAccel\| (m/s²) at last detected step.
    var lastStepPeakMs2: Double { get }
    /// Median peak acceleration (g) over recent steps — for Weinberg calibration.
    var medianRecentPeakG: Double { get }

    func start()
    func stop()
}

enum MotionStatus: Equatable {
    case ok
    case noPermission
    case noMotion
    case error(String)

    var isBlocked: Bool { if case .ok = self { return false } else { return true } }
    var message: String {
        switch self {
        case .ok:           return "OK"
        case .noPermission: return "Motion permissions are off. Enable Motion & Fitness in Settings."
        case .noMotion:     return "Motion sensor not available on this device."
        case .error(let m): return m
        }
    }
}

// MARK: - Real device implementation (uses CoreMotion + BodyTransform)

private struct MotionProcessingSnapshot {
    var carryMode: CarryMode = .handheld
    var weinbergK: Double?
    var heightCm: Int = 170
    var integration: LocomotionIntegrationParams = .init(
        locomotionSurface: .ground,
        treadmillUsesBeltSpeed: false,
        treadmillBeltMps: 0,
        paceSessionKind: .walk,
        carryMode: .handheld
    )
    var bodyTransform: OrientationTransformDTO?
    var orientationQualityGood: Bool = false
    var walkingHeadingOffsetRad: Double = 0
}

private struct PendingStepUI {
    let peakMs2: Double
    let medG: Double
    let mlAtStep: Double
    let newCadenceSPM: Double?
}

final class MotionServiceDevice: MotionServiceType {

    // Public (ObservableObject) outputs — mutate only on main queue
    @Published private(set) var stepCount: Int = 0
    @Published private(set) var cadenceSPM: Double = 0
    @Published private(set) var mlSwayRMS: Double = 0
    @Published private(set) var tiltDeg: Double = 0
    @Published private(set) var status: MotionStatus = .ok
    @Published private(set) var bodySample: (fwd: Double, ml: Double, up: Double) = (0,0,0)
    @Published private(set) var calibrationOK: Bool = false

    @Published private(set) var distanceM: Double = 0
    @Published private(set) var speedMps: Double = 0
    @Published private(set) var headingDeg: Double = 0
    @Published private(set) var trackPlanarPoints: [PlanarTrackPoint] = [PlanarTrackPoint(xM: 0, yM: 0)]
    @Published private(set) var planarXM: Double = 0
    @Published private(set) var planarYM: Double = 0
    @Published private(set) var lastStepPeakMs2: Double = 0
    @Published private(set) var medianRecentPeakG: Double = 0

    private let mm = CMMotionManager()
    /// Must be serial: Core Motion may enqueue updates faster than each handler finishes; concurrent
    /// handlers corrupt `[Double]` buffers and `HandheldStepDetector` state (fatal index crashes).
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    private let settings = UserSettingsStore.shared
    private let stepDetector = HandheldStepDetector()
    private let fusion = LocomotionFusion()
    private let pedCadence = PedometerCadenceMonitor()

    private let snapshotLock = NSLock()
    private var motionSnapshot = MotionProcessingSnapshot()

    private let cadenceLock = NSLock()
    /// Last cadence pushed to fusion from motion thread (written on main only).
    private var cadenceForFusion: Double = 0

    private let stepSubject = PassthroughSubject<(Date, Double), Never>()
    var stepEvent: AnyPublisher<(Date, Double), Never> { stepSubject.eraseToAnyPublisher() }

    private var mlBuffer: [Double] = []
    private let mlCap = 300

    private var lastCadenceTimestamp: TimeInterval = 0
    private var lastMotionTimestamp: TimeInterval?
    private var lastStrideM: Double = 0

    private var peakGsRing: [Double] = []

    private var tiltEMA: Double = 0
    private let tiltAlpha = 0.02

    private var settingsObservation: AnyCancellable?

    init() {
        refreshMotionSnapshotFromMain()
        settingsObservation = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMotionSnapshotFromMain() }
    }

    private func refreshMotionSnapshotFromMain() {
        let s = settings
        snapshotLock.lock()
        motionSnapshot = MotionProcessingSnapshot(
            carryMode: s.carryMode,
            weinbergK: s.weinbergK,
            heightCm: s.heightCmValue,
            integration: LocomotionIntegrationParams(
                locomotionSurface: s.locomotionSurface,
                treadmillUsesBeltSpeed: s.treadmillDistanceUsesBeltSpeed,
                treadmillBeltMps: s.treadmillBeltSpeedMps,
                paceSessionKind: s.paceSessionKind,
                carryMode: s.carryMode
            ),
            bodyTransform: s.bodyTransform,
            orientationQualityGood: s.orientationQuality?.isGood ?? false,
            walkingHeadingOffsetRad: s.walkingHeadingOffsetRad
        )
        snapshotLock.unlock()
    }

    private func readMotionSnapshot() -> MotionProcessingSnapshot {
        snapshotLock.lock()
        let snap = motionSnapshot
        snapshotLock.unlock()
        return snap
    }

    private static func bodyTransform(from dto: OrientationTransformDTO?) -> BodyTransform? {
        guard let dto else { return nil }
        let fwd = simd_double3(dto.m00, dto.m01, dto.m02)
        let ml  = simd_double3(dto.m10, dto.m11, dto.m12)
        let up  = simd_double3(dto.m20, dto.m21, dto.m22)
        return BodyTransform(fwd: fwd, ml: ml, up: up)
    }

    private static func attitudeFrameForLocomotion() -> CMAttitudeReferenceFrame {
        let magnetic = CMAttitudeReferenceFrame.xMagneticNorthZVertical
        if CMMotionManager.availableAttitudeReferenceFrames().contains(magnetic) {
            return magnetic
        }
        return .xArbitraryCorrectedZVertical
    }

    func start() {
        guard mm.isDeviceMotionAvailable else {
            status = .noMotion
            return
        }

        refreshMotionSnapshotFromMain()

        status = .ok
        stepCount = 0
        cadenceSPM = 0
        cadenceLock.lock()
        cadenceForFusion = 0
        cadenceLock.unlock()
        mlSwayRMS = 0
        tiltDeg = 0
        mlBuffer.removeAll()
        lastCadenceTimestamp = 0
        lastMotionTimestamp = nil
        tiltEMA = 0

        distanceM = 0
        speedMps = 0
        headingDeg = 0
        trackPlanarPoints = [PlanarTrackPoint(xM: 0, yM: 0)]
        planarXM = 0
        planarYM = 0
        lastStepPeakMs2 = 0
        medianRecentPeakG = 0

        stepDetector.reset()
        fusion.reset()
        trackPlanarPoints = fusion.trackSnapshot()

        let snap0 = readMotionSnapshot()
        lastStrideM = LocomotionMath.strideLengthMeters(
            peakAccelG: 1.0,
            weinbergK: snap0.weinbergK,
            heightCm: snap0.heightCm
        )
        peakGsRing.removeAll()

        pedCadence.stop()
        let pedSnap = readMotionSnapshot()
        let usePedCadence =
            pedSnap.carryMode == .handheld
            && pedSnap.integration.locomotionSurface != .treadmill
            && CMPedometer.isStepCountingAvailable()
        if usePedCadence {
            let startPed = Date()
            pedCadence.start(from: startPed, targetQueue: queue) { [weak self] spm in
                guard let self else { return }
                let snap = self.readMotionSnapshot()
                guard snap.carryMode == .handheld,
                      snap.integration.locomotionSurface != .treadmill
                else { return }

                var stride = max(self.lastStrideM, 0.28)
                if stride < 0.42 {
                    stride = LocomotionMath.strideLengthMeters(
                        peakAccelG: 0.48,
                        weinbergK: snap.weinbergK,
                        heightCm: snap.heightCm
                    )
                }
                self.fusion.ingestCadenceBackedSpeed(
                    strideLengthM: stride,
                    cadenceSPM: spm,
                    paceKind: snap.integration.paceSessionKind
                )
            }
        }

        mm.deviceMotionUpdateInterval = 1.0 / 100.0
        let frame = Self.attitudeFrameForLocomotion()

        mm.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] dm, err in
            guard let self else { return }
            if let err {
                DispatchQueue.main.async { self.status = .error(err.localizedDescription) }
                return
            }
            guard let dm else { return }

            let snap = self.readMotionSnapshot()
            let bodyT = Self.bodyTransform(from: snap.bodyTransform)
            let calOK = bodyT != nil && snap.orientationQualityGood

            let aDev = simd_double3(dm.userAcceleration.x, dm.userAcceleration.y, dm.userAcceleration.z)
            let gDev = simd_double3(dm.gravity.x, dm.gravity.y, dm.gravity.z)

            let (fwd, ml, up): (Double, Double, Double) = {
                if let T = bodyT, calOK {
                    let ab = T.apply(aDev)
                    return (ab.forward, ab.ml, ab.up)
                } else {
                    return (aDev.x, aDev.y, aDev.z)
                }
            }()

            self.mlBuffer.append(ml)
            if self.mlBuffer.count > self.mlCap {
                self.mlBuffer.removeFirst(self.mlBuffer.count - self.mlCap)
            }
            let meanSq = self.mlBuffer.reduce(0) { $0 + $1 * $1 } / Double(max(1, self.mlBuffer.count))
            let mlRMS = sqrt(meanSq)

            if let T = bodyT, calOK {
                let gb = T.apply(gDev)
                let horiz = sqrt(gb.forward * gb.forward + gb.ml * gb.ml)
                let newTilt = atan2(horiz, abs(gb.up)) * 180.0 / .pi
                self.tiltEMA = (self.tiltEMA == 0)
                    ? newTilt
                    : (self.tiltAlpha * newTilt + (1 - self.tiltAlpha) * self.tiltEMA)
            }

            let now = dm.timestamp
            let gyro = simd_double3(dm.rotationRate.x, dm.rotationRate.y, dm.rotationRate.z)

            self.fusion.ingestHeading(yawRadians: dm.attitude.yaw)

            if self.lastCadenceTimestamp > 0, now - self.lastCadenceTimestamp > 3.2 {
                self.cadenceLock.lock()
                self.cadenceForFusion = 0
                self.cadenceLock.unlock()
            }

            self.cadenceLock.lock()
            let cadUse = self.cadenceForFusion
            self.cadenceLock.unlock()

            let paceKind = snap.integration.paceSessionKind
            let cadenceHintFloor = paceKind == .run ? 138.0 : 72.0

            if let prev = self.lastMotionTimestamp {
                let dt = now - prev
                self.fusion.ingestMotionTick(dt: dt, params: snap.integration)
            }
            self.lastMotionTimestamp = now

            let peakMs2Opt = self.stepDetector.analyze(
                timestamp: now,
                fwd: fwd,
                ml: ml,
                up: up,
                gyro: gyro,
                carryMode: snap.carryMode,
                calibrationOK: calOK,
                cadenceHintSPM: max(cadUse, cadenceHintFloor)
            )

            var pendingStep: PendingStepUI?
            if let peakMs2 = peakMs2Opt {
                let peakG = LocomotionMath.peakAccelG(fromMagnitudeMs2: peakMs2)
                let stride = LocomotionMath.strideLengthMeters(
                    peakAccelG: peakG,
                    weinbergK: snap.weinbergK,
                    heightCm: snap.heightCm
                )
                self.lastStrideM = stride
                self.fusion.ingestStepStride(strideLengthM: stride, params: snap.integration)
                self.fusion.ingestStepPlanar(
                    strideLengthM: stride,
                    yawRadians: dm.attitude.yaw,
                    headingOffsetRad: snap.walkingHeadingOffsetRad,
                    params: snap.integration
                )

                self.peakGsRing.append(peakG)
                if self.peakGsRing.count > 48 { self.peakGsRing.removeFirst(self.peakGsRing.count - 48) }
                let sorted = self.peakGsRing.sorted()
                let medG: Double = {
                    guard !sorted.isEmpty else { return peakG }
                    let mid = sorted.count / 2
                    return sorted[mid]
                }()

                var newCadenceSPM: Double?
                var stepPeriodForSpeed: TimeInterval?
                if self.lastCadenceTimestamp > 0 {
                    let dtStep = now - self.lastCadenceTimestamp
                    let minDt = paceKind == .run ? 0.16 : 0.22
                    let periodLow = paceKind == .run ? 0.22 : 0.28
                    // Shuttle / turn: gaps may exceed 2 s — still refresh speed; cadence UI only when rhythm is plausible.
                    if dtStep > minDt && dtStep < 6.5 {
                        let periodSpeed = min(max(dtStep, periodLow), 3.5)
                        stepPeriodForSpeed = periodSpeed
                        if dtStep <= 2.8 {
                            newCadenceSPM = min(200, max(0, 60.0 / dtStep))
                        }
                    }
                }
                self.lastCadenceTimestamp = now

                if let period = stepPeriodForSpeed {
                    self.fusion.ingestWalkStepSpeed(strideLengthM: stride, stepPeriod: period, paceKind: paceKind)
                }

                pendingStep = PendingStepUI(
                    peakMs2: peakMs2,
                    medG: medG,
                    mlAtStep: ml,
                    newCadenceSPM: newCadenceSPM
                )
            }

            let lastCadTS = self.lastCadenceTimestamp
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let tel = self.fusion.telemetrySnapshot()
                self.bodySample = (fwd, ml, up)
                self.calibrationOK = calOK
                self.mlSwayRMS = mlRMS
                self.tiltDeg = self.tiltEMA
                self.distanceM = tel.distanceM
                self.speedMps = tel.speedMps
                self.headingDeg = tel.headingDeg
                self.planarXM = tel.planarXM
                self.planarYM = tel.planarYM

                let cadenceIdle = lastCadTS > 0 && (now - lastCadTS) > 3.2
                if cadenceIdle {
                    self.cadenceSPM = 0
                }

                if let p = pendingStep {
                    self.trackPlanarPoints = self.fusion.trackSnapshot()
                    self.stepCount += 1
                    self.lastStepPeakMs2 = p.peakMs2
                    self.medianRecentPeakG = p.medG
                    self.stepSubject.send((Date(), p.mlAtStep))
                    if let spm = p.newCadenceSPM {
                        self.cadenceSPM = spm
                        self.cadenceLock.lock()
                        self.cadenceForFusion = spm
                        self.cadenceLock.unlock()
                    }
                }
            }
        }
    }

    func stop() {
        pedCadence.stop()
        mm.stopDeviceMotionUpdates()
        lastMotionTimestamp = nil
    }
}

// MARK: - Simulator stub (keeps UI working in Simulator)

final class MotionServiceSim: MotionServiceType {
    @Published private(set) var stepCount: Int = 0
    @Published private(set) var cadenceSPM: Double = 96
    @Published private(set) var mlSwayRMS: Double = 0.06
    @Published private(set) var tiltDeg: Double = 0
    @Published private(set) var status: MotionStatus = .ok
    @Published private(set) var bodySample: (fwd: Double, ml: Double, up: Double) = (0.1, 0.0, 0.98)
    @Published private(set) var calibrationOK: Bool = true

    @Published private(set) var distanceM: Double = 0
    @Published private(set) var speedMps: Double = 0
    @Published private(set) var headingDeg: Double = 12
    @Published private(set) var trackPlanarPoints: [PlanarTrackPoint] = [PlanarTrackPoint(xM: 0, yM: 0)]
    @Published private(set) var planarXM: Double = 0
    @Published private(set) var planarYM: Double = 0
    @Published private(set) var lastStepPeakMs2: Double = 3.5
    @Published private(set) var medianRecentPeakG: Double = 0.42

    private let stepSubject = PassthroughSubject<(Date, Double), Never>()
    var stepEvent: AnyPublisher<(Date, Double), Never> { stepSubject.eraseToAnyPublisher() }

    private var timer: AnyCancellable?
    private var mlSign: Double = 1
    private var fusionStub = LocomotionFusion()
    private var simYawRad: Double = 0

    init() {}

    func start() {
        status = .ok
        stepCount = 0
        cadenceSPM = 96
        mlSwayRMS = 0.06
        tiltDeg = 2
        fusionStub.reset()
        distanceM = 0
        speedMps = 0
        headingDeg = 10
        trackPlanarPoints = fusionStub.trackSnapshot()
        planarXM = 0
        planarYM = 0
        simYawRad = 0.25

        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.stepCount += 1
                self.mlSign *= -1
                let ml = 0.08 * self.mlSign + Double.random(in: -0.01...0.01)
                self.mlSwayRMS = 0.05 + Double.random(in: -0.01...0.01)
                self.cadenceSPM = 92 + Double.random(in: -5...5)
                self.bodySample = (0.2, ml, 0.95)
                let stride = LocomotionMath.strideLengthMeters(peakAccelG: 0.45, weinbergK: nil, heightCm: 170)
                let s = UserSettingsStore.shared
                let params = LocomotionIntegrationParams(
                    locomotionSurface: s.locomotionSurface,
                    treadmillUsesBeltSpeed: s.treadmillDistanceUsesBeltSpeed,
                    treadmillBeltMps: s.treadmillBeltSpeedMps,
                    paceSessionKind: s.paceSessionKind,
                    carryMode: s.carryMode
                )
                self.fusionStub.ingestMotionTick(dt: 0.5, params: params)
                self.fusionStub.ingestWalkStepSpeed(strideLengthM: stride, stepPeriod: 0.5, paceKind: params.paceSessionKind)
                self.fusionStub.ingestStepStride(strideLengthM: stride, params: params)
                self.simYawRad += 0.12
                self.fusionStub.ingestHeading(yawRadians: self.simYawRad)
                self.fusionStub.ingestStepPlanar(
                    strideLengthM: stride,
                    yawRadians: self.simYawRad,
                    headingOffsetRad: s.walkingHeadingOffsetRad,
                    params: params
                )
                let tel = self.fusionStub.telemetrySnapshot()
                self.distanceM = tel.distanceM
                self.speedMps = tel.speedMps
                self.headingDeg = tel.headingDeg
                self.planarXM = tel.planarXM
                self.planarYM = tel.planarYM
                self.trackPlanarPoints = self.fusionStub.trackSnapshot()
                self.lastStepPeakMs2 = 3.2 + Double.random(in: -0.3...0.3)
                self.medianRecentPeakG = 0.41
                self.stepSubject.send((Date(), ml))
            }
    }

    func stop() { timer?.cancel(); timer = nil }
}

// MARK: - Environment switch

#if targetEnvironment(simulator)
typealias MotionService = MotionServiceSim
#else
typealias MotionService = MotionServiceDevice
#endif

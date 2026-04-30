import CoreMotion
import Foundation

/// Streams **cadence (steps/min)** from `CMPedometer` onto the same serial queue as device motion so
/// `LocomotionFusion` can estimate pace while handheld (weak heel-strike signature on raw accel).
final class PedometerCadenceMonitor {
    private let ped = CMPedometer()
    private var lastSteps: Int = 0
    private var lastDate: Date?

    func start(from startDate: Date, targetQueue: OperationQueue, handler: @escaping (Double) -> Void) {
        stop()
        lastSteps = 0
        lastDate = nil
        guard CMPedometer.isStepCountingAvailable() else { return }

        ped.startUpdates(from: startDate) { [weak self] data, error in
            guard error == nil, let self, let data else { return }
            targetQueue.addOperation {
                guard let spm = self.computeCadenceSPM(data) else { return }
                handler(spm)
            }
        }
    }

    func stop() {
        ped.stopUpdates()
    }

    /// `currentCadence` is **steps per second** — convert to SPM. Fallback: step-count deltas vs `endDate`.
    private func computeCadenceSPM(_ data: CMPedometerData) -> Double? {
        let anchor = data.endDate

        if let c = data.currentCadence?.doubleValue, c > 0 {
            let spm = c * 60.0
            if spm >= 34 && spm <= 220 {
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

        guard dt > 0.22, ds >= 1 else { return nil }
        let spm = Double(ds) / dt * 60.0
        guard spm >= 34 && spm <= 220 else { return nil }
        return spm
    }
}

import Foundation
import HealthKit

/// Centralized HealthKit access layer for GaitCoach.
/// - iOS 17+, Swift Concurrency (async/await)
/// - Supports background delivery (Observer + Anchored queries)
@MainActor
final class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()
    private var observers: [Metric: HKObserverQuery] = [:]

    /// Persisted anchors per metric so we only fetch deltas.
    private let anchorStore = AnchorStore()

    enum Metric: CaseIterable, Hashable {
        case walkingAsymmetryPercentage
        case stepLength
        case walkingSpeed
        case doubleSupportPercentage

        var quantityTypeIdentifier: HKQuantityTypeIdentifier {
            switch self {
            case .walkingAsymmetryPercentage: return .walkingAsymmetryPercentage
            case .stepLength:                 return .walkingStepLength
            case .walkingSpeed:               return .walkingSpeed
            case .doubleSupportPercentage:    return .walkingDoubleSupportPercentage
            }
        }

        /// Preferred HKUnit for display.
        var unit: HKUnit {
            switch self {
            case .walkingAsymmetryPercentage, .doubleSupportPercentage:
                return .percent()
            case .stepLength:
                return .meter()
            case .walkingSpeed:
                return .meter().unitDivided(by: .second())
            }
        }

        var title: String {
            switch self {
            case .walkingAsymmetryPercentage: return "Walking Asymmetry"
            case .stepLength:                 return "Step Length"
            case .walkingSpeed:               return "Walking Speed"
            case .doubleSupportPercentage:    return "Double Support"
            }
        }

        fileprivate var anchorKey: String {
            "hk.anchor.\(quantityTypeIdentifier.rawValue)"
        }

        /// Whether this metric should show deltas as percentage points (pp) instead of relative %.
        var isPercentLike: Bool {
            switch self {
            case .walkingAsymmetryPercentage, .doubleSupportPercentage:
                return true
            default:
                return false
            }
        }
    }

    @Published private(set) var authorizationGranted = false
    @Published private(set) var latestValues: [Metric: HKQuantitySample] = [:]

    private init() {}

    // MARK: - Authorization

    func requestAuthorization(for metrics: Set<Metric>) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let readTypes: Set<HKObjectType> = Set(
            metrics.compactMap { HKObjectType.quantityType(forIdentifier: $0.quantityTypeIdentifier) }
        )
        try await store.requestAuthorization(toShare: [], read: readTypes)
        authorizationGranted = readTypes.allSatisfy { store.authorizationStatus(for: $0) == .sharingAuthorized }
    }

    // MARK: - Foreground fetching (Today latest)

    /// Fetch the most recent sample for a metric between startOfDay and now.
    func fetchTodayLatest(for metric: Metric) async throws -> HKQuantitySample? {
        let type = HKObjectType.quantityType(forIdentifier: metric.quantityTypeIdentifier)!
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date(), options: .strictStartDate)

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        let results = try await descriptor.result(for: store)
        let latest = results.first as? HKQuantitySample
        if let latest { latestValues[metric] = latest }
        return latest
    }

    /// Convenience: fetch multiple metrics (today) at once.
    func fetchTodayLatest(for metrics: Set<Metric>) async {
        for metric in metrics {
            _ = try? await fetchTodayLatest(for: metric)
        }
    }

    // MARK: - History fetching (rolling window)

    /// Fetch **all** samples for a metric between `start` and `end`.
    func fetchSamples(for metric: Metric, start: Date, end: Date) async throws -> [HKQuantitySample] {
        let type = HKObjectType.quantityType(forIdentifier: metric.quantityTypeIdentifier)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: HKObjectQueryNoLimit
        )
        let results = try await descriptor.result(for: store)
        return results.compactMap { $0 as? HKQuantitySample }
    }

    // MARK: - Background delivery

    /// Start HealthKit background delivery for provided metrics.
    /// Call this once after authorization (e.g., at app start or from a card).
    func startBackgroundDelivery(for metrics: Set<Metric>) async {
        guard authorizationGranted else { return }

        for metric in metrics {
            guard let type = HKObjectType.quantityType(forIdentifier: metric.quantityTypeIdentifier) else { continue }

            do {
                try await store.enableBackgroundDelivery(for: type, frequency: .immediate)
            } catch {
                // Not fatal
            }

            let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                guard let self else { completion(); return }
                if error != nil { completion(); return }

                Task { @MainActor in
                    await self.fetchChanges(for: metric)
                    completion()
                }
            }
            store.execute(observer)
            observers[metric] = observer

            await fetchChanges(for: metric)
        }
    }

    func stopBackgroundDelivery() {
        for (_, q) in observers {
            store.stop(q)
        }
        observers.removeAll()
    }

    private func fetchChanges(for metric: Metric) async {
        guard let type = HKObjectType.quantityType(forIdentifier: metric.quantityTypeIdentifier) else { return }

        let anchor = anchorStore.anchor(forKey: metric.anchorKey)

        let query = HKAnchoredObjectQuery(type: type,
                                          predicate: nil,
                                          anchor: anchor,
                                          limit: HKObjectQueryNoLimit) { [weak self] _, newSamples, _, newAnchor, error in
            guard let self else { return }
            if let newAnchor { self.anchorStore.setAnchor(newAnchor, forKey: metric.anchorKey) }
            if error != nil { return }

            if let samples = newSamples as? [HKQuantitySample],
               let newest = samples.sorted(by: { $0.endDate > $1.endDate }).first {
                Task { @MainActor in
                    self.latestValues[metric] = newest
                }
            }
        }
        store.execute(query)
    }

    // MARK: - Formatting helpers

    func formattedValue(for metric: Metric, sample: HKQuantitySample?) -> String {
        guard let sample else { return "—" }
        let value = sample.quantity.doubleValue(for: metric.unit)

        switch metric {
        case .walkingAsymmetryPercentage, .doubleSupportPercentage:
            // HealthKit stores percent as 1.0 = 100%
            return String(format: "%.1f%%", value * 100.0)
        case .stepLength:
            if value < 1.0 {
                return String(format: "%.0f cm", value * 100.0)
            } else {
                return String(format: "%.2f m", value)
            }
        case .walkingSpeed:
            return String(format: "%.2f m/s", value)
        }
    }

    /// Raw (unformatted) numeric value for calculations, already converted to display unit.
    func numericValue(for metric: Metric, sample: HKQuantitySample?) -> Double? {
        guard let sample else { return nil }
        return sample.quantity.doubleValue(for: metric.unit)
    }
}

// MARK: - Anchor persistence

/// Stores/retrieves HKQueryAnchor in UserDefaults (securely archived).
private final class AnchorStore {
    private let defaults = UserDefaults.standard

    func anchor(forKey key: String) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            defer { unarchiver.finishDecoding() }
            return HKQueryAnchor(coder: unarchiver)
        } catch {
            return nil
        }
    }

    func setAnchor(_ anchor: HKQueryAnchor, forKey key: String) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        anchor.encode(with: archiver)
        archiver.finishEncoding()
        UserDefaults.standard.set(archiver.encodedData, forKey: key)
    }
}


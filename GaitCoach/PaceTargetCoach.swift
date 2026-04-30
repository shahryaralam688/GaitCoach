import Foundation

/// Coaching zone vs a numeric pace target (km/h). Uses sensor-derived pace — not GPS-grade truth.
enum PaceCoachZone: Equatable {
    case idle
    case slow
    case onTarget
    case fast
}

enum PaceCoach {

    /// - Parameters:
    ///   - actualKmh: Low-pass smoothed speed (km/h) from fusion.
    ///   - cadenceSPM: Used to suppress coaching while effectively stationary.
    ///   - targetKmh: User goal for current Walk / Run mode.
    ///   - toleranceFraction: Half-band around target as a fraction (e.g. 0.12 ±12%).
    static func zone(
        actualKmh: Double,
        cadenceSPM: Double,
        targetKmh: Double,
        toleranceFraction: Double
    ) -> PaceCoachZone {
        guard targetKmh >= 0.8 else { return .idle }
        let tol = max(0.04, min(0.35, toleranceFraction))

        if actualKmh < 0.65 && cadenceSPM < 18 {
            return .idle
        }

        let low = targetKmh * (1 - tol)
        let high = targetKmh * (1 + tol)

        if actualKmh < low { return .slow }
        if actualKmh > high { return .fast }
        return .onTarget
    }

    static func toleranceFraction(fromPercent pct: Double) -> Double {
        max(4, min(35, pct)) / 100.0
    }
}

enum PaceSessionKind: String, CaseIterable, Identifiable {
    case walk
    case run

    var id: String { rawValue }

    var label: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        }
    }

    func targetKmh(settings: UserSettingsStore) -> Double {
        switch self {
        case .walk: return settings.paceTargetWalkKmh
        case .run: return settings.paceTargetRunKmh
        }
    }
}

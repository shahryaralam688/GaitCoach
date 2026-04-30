import Foundation

/// How the phone is carried during locomotion sessions (affects calibration duration + step gating).
enum CarryMode: String, CaseIterable, Codable, Identifiable, Hashable {
    case pocket
    case handheld

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pocket: return "Pocket"
        case .handheld: return "Handheld"
        }
    }

    /// Orientation PCA calibration duration (seconds).
    var calibrationWalkSeconds: Double {
        switch self {
        case .pocket: return 10
        case .handheld: return 12
        }
    }
}

/// Indoor / treadmill surface selection — affects distance integration rules.
enum LocomotionSurface: String, CaseIterable, Codable, Identifiable, Hashable {
    case ground
    case treadmill

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ground: return "Ground / indoor"
        case .treadmill: return "Treadmill"
        }
    }
}

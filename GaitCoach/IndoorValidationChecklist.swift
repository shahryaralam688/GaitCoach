import Foundation

/// Offline QA checklist for reporting indoor IMU pace accuracy (no GPS).
enum IndoorValidationChecklist {

    static let title = "Indoor IMU validation checklist"

    static let treadmillSteps: [String] = [
        "Select Treadmill surface and enable Distance from belt speed in Settings.",
        "Set belt speed to a known value on the treadmill UI (km/h).",
        "Run for ≥60 s at steady belt speed; compare mean displayed speed and total distance vs belt × time.",
        "Repeat at least two belt speeds (e.g. slow walk, brisk walk / slow run).",
        "Optional: disable belt integration and note that distance from steps is not ground truth on a treadmill.",
    ]

    static let tapedStraightLine: [String] = [
        "Calibrate Weinberg K on a measured straight path (tape measure) of ≥15 m.",
        "Walk normally (handheld carry as in real use); record app distance at the end marker vs tape length.",
        "Repeat 3 trials; mean error and std dev can be quoted in release notes.",
    ]

    static let curvedPath: [String] = [
        "Use a measuring wheel or known loop perimeter for a non-linear path.",
        "Use Set forward calibration on Calibrate tab with phone held in final carry pose.",
        "Compare accumulated path length (sum of strides) vs wheel / known arc length—not loop closure gap (expected with indoor yaw).",
        "Report closure error separately from path-length error.",
    ]

    static let shortShuttle: [String] = [
        "For 3–5 m shuttles expect high relative error in the first few steps; quote results only after ≥10–15 steps.",
    ]

    static func allBulletedText() -> String {
        func block(_ heading: String, _ items: [String]) -> String {
            heading + "\n" + items.map { "• \($0)" }.joined(separator: "\n")
        }
        return [
            block("Treadmill (belt integration)", treadmillSteps),
            block("Straight-line (tape)", tapedStraightLine),
            block("Curved / loop (path length)", curvedPath),
            block("Short shuttles", shortShuttle),
        ].joined(separator: "\n\n")
    }
}

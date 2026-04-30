import Foundation

/// Planar pedestrian dead reckoning helpers (horizontal plane, yaw = heading about vertical).
enum PedestrianPlanarMath {

    /// Wrap angle to (-π, π].
    static func wrapPi(_ rad: Double) -> Double {
        var a = rad.truncatingRemainder(dividingBy: 2 * .pi)
        if a <= -.pi { a += 2 * .pi }
        if a > .pi { a -= 2 * .pi }
        return a
    }

    /// Displacement for one stride along heading θ (yaw about gravity, CCW positive).
    static func deltaXY(strideMeters L: Double, headingRad θ: Double) -> (dx: Double, dy: Double) {
        let dx = L * cos(θ)
        let dy = L * sin(θ)
        return (dx, dy)
    }
}

/// One vertex of the horizontal trace (meters, arbitrary planar origin).
struct PlanarTrackPoint: Equatable, Sendable {
    var xM: Double
    var yM: Double
}

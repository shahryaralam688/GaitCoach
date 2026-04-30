//
//  GaitCoachTests.swift
//  GaitCoachTests
//

import Testing
@testable import GaitCoach

struct LocomotionMathTests {

    @Test func anthropometricStrideFallback() {
        let L = LocomotionMath.strideLengthMeters(peakAccelG: 0.02, weinbergK: nil, heightCm: 170)
        #expect(L > 0.5 && L < 0.95)
    }

    @Test func weinbergChangesWhenKPresent() {
        let noK = LocomotionMath.strideLengthMeters(peakAccelG: 0.55, weinbergK: nil, heightCm: 175)
        let withK = LocomotionMath.strideLengthMeters(peakAccelG: 0.55, weinbergK: 0.52, heightCm: 175)
        #expect(abs(withK - noK) > 0.02)
    }

    @Test func estimateWeinbergKSanity() {
        let K = LocomotionMath.estimateWeinbergK(knownDistanceM: 100, steps: 120, medianPeakG: 0.42)
        #expect(K != nil)
        #expect(K! > 0.35 && K! < 2.5)
    }

    @Test func peakAccelGScalesWithGravity() {
        let g = LocomotionMath.peakAccelG(fromMagnitudeMs2: 19.6133)
        #expect(abs(g - 2.0) < 0.02)
    }
}

struct PaceCoachTests {

    @Test func onTargetMidBand() {
        let z = PaceCoach.zone(actualKmh: 5.0, cadenceSPM: 95, targetKmh: 5.0, toleranceFraction: 0.12)
        #expect(z == .onTarget)
    }

    @Test func slowWhenTooLow() {
        let z = PaceCoach.zone(actualKmh: 3.0, cadenceSPM: 95, targetKmh: 6.0, toleranceFraction: 0.12)
        #expect(z == .slow)
    }

    @Test func fastWhenTooHigh() {
        let z = PaceCoach.zone(actualKmh: 14.0, cadenceSPM: 165, targetKmh: 10.0, toleranceFraction: 0.12)
        #expect(z == .fast)
    }

    @Test func idleWhenStationary() {
        let z = PaceCoach.zone(actualKmh: 0.1, cadenceSPM: 0, targetKmh: 8.0, toleranceFraction: 0.12)
        #expect(z == .idle)
    }

    @Test func idleWhenTargetUnset() {
        let z = PaceCoach.zone(actualKmh: 6.0, cadenceSPM: 120, targetKmh: 0.5, toleranceFraction: 0.12)
        #expect(z == .idle)
    }
}

struct PedestrianPlanarMathTests {

    @Test func deltaXYEast() {
        let d = PedestrianPlanarMath.deltaXY(strideMeters: 2, headingRad: 0)
        #expect(abs(d.dx - 2) < 1e-9 && abs(d.dy) < 1e-9)
    }

    @Test func deltaXYNorth() {
        let d = PedestrianPlanarMath.deltaXY(strideMeters: 1, headingRad: .pi / 2)
        #expect(abs(d.dx) < 1e-9 && abs(d.dy - 1) < 1e-9)
    }

    @Test func wrapPiBringsNearPi() {
        let w = PedestrianPlanarMath.wrapPi(3 * .pi / 2)
        #expect(abs(w - (-.pi / 2)) < 1e-9)
    }
}

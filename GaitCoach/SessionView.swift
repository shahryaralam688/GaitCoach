import SwiftUI
import Combine
import AudioToolbox
import UIKit

private let darkGreen = Color(red: 39/255, green: 77/255, blue: 67/255) // #274D43

// MARK: - Lightweight metrics helper (labels feet from ML sign)
private final class LiveStepStats {
    // public outputs
    private(set) var avgStepTime: Double = 0        // seconds
    private(set) var stepTimeCV: Double = 0         // 0..1
    private(set) var asymPct: Double = 0            // %

    // config
    private let maxPairs = 40                        // ~20 L/R pairs
    private let minDt: Double = 0.25
    private let maxDt: Double = 1.6
    private let mlDeadband: Double = 0.01           // ignore tiny ML near zero

    // state
    private var lastTime: Date?
    private var allDts: [Double] = []
    private var leftDts: [Double] = []
    private var rightDts: [Double] = []

    func reset() {
        lastTime = nil
        allDts.removeAll()
        leftDts.removeAll()
        rightDts.removeAll()
        avgStepTime = 0
        stepTimeCV = 0
        asymPct = 0
    }

    func ingest(time: Date, ml: Double) {
        if let t0 = lastTime {
            let dt = time.timeIntervalSince(t0)
            guard dt >= minDt && dt <= maxDt else { lastTime = time; return }

            allDts.append(dt)
            trim(&allDts, to: maxPairs * 2)

            // ML > 0 => subject-left
            if ml > mlDeadband { leftDts.append(dt); trim(&leftDts, to: maxPairs) }
            else if ml < -mlDeadband { rightDts.append(dt); trim(&rightDts, to: maxPairs) }

            recompute()
        }
        lastTime = time
    }

    private func recompute() {
        if !allDts.isEmpty {
            let m = mean(allDts)
            avgStepTime = m
            if allDts.count >= 5 {
                let v = variance(allDts, mean: m)
                stepTimeCV = m > 0 ? sqrt(v / Double(max(1, allDts.count - 1))) / m : 0
            } else {
                stepTimeCV = 0
            }
        } else { avgStepTime = 0; stepTimeCV = 0 }

        if leftDts.count >= 2 && rightDts.count >= 2 {
            let L = mean(Array(leftDts.suffix(10)))
            let R = mean(Array(rightDts.suffix(10)))
            let denom = max(0.0001, (L + R) / 2.0)
            asymPct = abs(L - R) / denom * 100.0
        } else { asymPct = 0 }
    }

    // utils
    private func trim(_ a: inout [Double], to cap: Int) { if a.count > cap { a.removeFirst(a.count - cap) } }
    private func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(max(1, xs.count)) }
    private func variance(_ xs: [Double], mean m: Double) -> Double { xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) }
}

// MARK: - SessionView

struct SessionView: View {
    @StateObject private var motion   = MotionService()
    @StateObject private var settings = UserSettingsStore.shared

    // Pocket side (UserDefaults)
    @AppStorage("pocketSide") private var pocketSideRaw: String = PocketSide.left.rawValue
    /// Walk vs Run selects which saved target pace applies (More → Settings).
    @AppStorage("paceSessionKind") private var paceKindRaw: String = PaceSessionKind.walk.rawValue

    private var paceSessionKind: PaceSessionKind {
        PaceSessionKind(rawValue: paceKindRaw) ?? .walk
    }

    private var pocketSideLabel: String { pocketSideRaw == PocketSide.right.rawValue ? "Right" : "Left" }

    // run state
    @State private var isRunning = false
    @State private var sessionStart: Date?
    @State private var steps = 0

    // live metrics
    @State private var stats = LiveStepStats()
    @State private var stepC: AnyCancellable?

    // simple poll
    private let pollInterval = Timer.publish(every: 0.25, on: .main, in: .common)

    // last completed session
    @State private var last: SessionSummary?

    // deviation alert
    @State private var lastAlertAt: Date = .distantPast
    private let alertCooldown: TimeInterval = 30
    private let asymWarnPct: Double = 12.0
    private let mlWarnAbs: Double = 0.10

    /// Low-pass pace (km/h) so coaching compares stable values to target.
    @State private var displaySpeedKmh: Double = 0
    @State private var lastCoachZone: PaceCoachZone = .idle

    var body: some View {
        NavigationStack {
            List {
                // Main session card
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Walk Session").font(.title.bold())
                        Text(isRunning ? "Running…" : "Idle").foregroundStyle(.secondary)

                        Picker("Mode", selection: Binding(
                            get: { PaceSessionKind(rawValue: paceKindRaw) ?? .walk },
                            set: { paceKindRaw = $0.rawValue }
                        )) {
                            ForEach(PaceSessionKind.allCases) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isRunning)

                        if settings.paceTargetCoachingEnabled {
                            let tgt = paceSessionKind.targetKmh(settings: settings)
                            Text("Target (\(paceSessionKind.label)): \(String(format: "%.1f km/h", tgt)) ±\(Int(settings.paceTargetTolerancePct.rounded()))%")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 28) {
                            metric("Steps", "\(steps)")
                            metric("Cadence", "\(Int(motion.cadenceSPM.rounded())) spm")
                            metric("M/L sway", String(format: "%.3f g", motion.mlSwayRMS))
                        }

                        HStack(spacing: 28) {
                            metric("Distance", formatDistance(motion.distanceM))
                            metric("Live speed", String(format: "%.2f km/h", motion.speedMps * 3.6))
                            metric("Heading", String(format: "%.0f°", motion.headingDeg))
                        }
                        Text("No GPS — speed updates from phone motion & steps in real time.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if settings.paceTargetCoachingEnabled && isRunning {
                            paceCoachBanner(
                                zone: currentCoachZone(),
                                targetKmh: paceSessionKind.targetKmh(settings: settings),
                                actualKmh: displaySpeedKmh
                            )
                            .padding(.vertical, 6)
                        }

                        if settings.locomotionSurface != .treadmill {
                            PlanarTraceMiniMap(points: motion.trackPlanarPoints)
                                .opacity(isRunning || motion.trackPlanarPoints.count > 1 ? 1 : 0.35)
                            Text("2D trace is step-based dead reckoning with compass yaw — approximate indoors; curved paths won’t close like GPS.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("2D floor trace is disabled on treadmill sessions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Step-time Asymmetry").font(.headline)
                            Text(String(format: "%.1f %%", stats.asymPct))
                                .font(.title3.monospacedDigit())
                                .foregroundStyle(colorForAsym(stats.asymPct))
                        }

                        HStack {
                            Button(isRunning ? "Stop" : "Start") { toggle() }
                                .buttonStyle(.borderedProminent)
                                .tint(darkGreen)
                                .foregroundStyle(.white)

                            Button("Reset") { reset() }
                                .buttonStyle(.bordered)
                                .tint(darkGreen)
                                .disabled(isRunning)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 2)
                }

                // Calibration info + tiny debug line
                Section {
                    HStack {
                        Text("Pocket").foregroundStyle(.secondary)
                        Spacer()
                        Text(pocketSideLabel)
                    }
                    HStack {
                        Text("Calibration quality").foregroundStyle(.secondary)
                        Spacer()
                        if let q = settings.orientationQuality {
                            Text(q.isGood ? "✅ Good" : "⚠️ Low").fontWeight(.semibold)
                        } else { Text("—") }
                    }
                    HStack {
                        Text("Carry mode").foregroundStyle(.secondary)
                        Spacer()
                        Text(settings.carryMode.label)
                    }
                    #if DEBUG
                    Divider()
                    Text(String(
                        format: "debug — fwd: %.2f  ml: %.2f  up: %.2f",
                        motion.bodySample.fwd, motion.bodySample.ml, motion.bodySample.up
                    ))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    #endif
                } header: { Text("CALIBRATION") }

                // Last session card
                if let s = last {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Last Session").font(.headline)
                            HStack {
                                Text("Score: \(s.symmetryScore)")
                                Spacer()
                                Text("Steps: \(s.steps)")
                                Spacer()
                                Text(String(format: "Cadence: %.0f spm", s.cadenceSPM))
                                Spacer()
                                if let d = s.distanceM {
                                    Text(String(format: "%.2f km", d / 1000))
                                    Spacer()
                                }
                                Text(String(format: "M/L sway: %.3f g", s.mlSwayRMS))
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .gcBackground()
            .listStyle(.insetGrouped)
            .listRowBackground(Color.white)
            .listSectionSpacing(12)
            .navigationTitle("Walk")
        }
        .onAppear {
            motion.start()
            // stream of body-frame steps → metrics
            stepC = motion.stepEvent.sink { (time, ml) in
                stats.ingest(time: time, ml: ml)
                checkDeviation()
            }
        }
        .onReceive(pollInterval.autoconnect()) { _ in
            steps = motion.stepCount
            let instant = motion.speedMps * 3.6
            if displaySpeedKmh <= 0.04 && instant <= 0.04 {
                displaySpeedKmh = instant
            } else {
                displaySpeedKmh = displaySpeedKmh <= 0.04 ? instant : (0.22 * instant + 0.78 * displaySpeedKmh)
            }

            guard isRunning, settings.paceTargetCoachingEnabled else { return }

            let kind = PaceSessionKind(rawValue: paceKindRaw) ?? .walk
            let target = kind.targetKmh(settings: settings)
            let frac = PaceCoach.toleranceFraction(fromPercent: settings.paceTargetTolerancePct)
            let z = PaceCoach.zone(
                actualKmh: displaySpeedKmh,
                cadenceSPM: motion.cadenceSPM,
                targetKmh: target,
                toleranceFraction: frac
            )
            if z != lastCoachZone {
                if settings.hapticCueingEnabled && (z == .slow || z == .fast) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                lastCoachZone = z
            }
        }
        .onDisappear {
            motion.stop()
            stepC?.cancel(); stepC = nil
        }
    }

    // MARK: - UI bits

    private func metric(_ title: String, _ value: String) -> some View {
        VStack { Text(title).font(.caption); Text(value).font(.title3.monospacedDigit()) }
    }

    private func currentCoachZone() -> PaceCoachZone {
        let target = paceSessionKind.targetKmh(settings: settings)
        let frac = PaceCoach.toleranceFraction(fromPercent: settings.paceTargetTolerancePct)
        return PaceCoach.zone(
            actualKmh: displaySpeedKmh,
            cadenceSPM: motion.cadenceSPM,
            targetKmh: target,
            toleranceFraction: frac
        )
    }

    @ViewBuilder
    private func paceCoachBanner(zone: PaceCoachZone, targetKmh: Double, actualKmh: Double) -> some View {
        let tgt = String(format: "%.1f", targetKmh)
        let act = String(format: "%.1f", actualKmh)
        switch zone {
        case .idle:
            Text("Move steadily — coaching compares your pace to \(tgt) km/h.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))

        case .onTarget:
            Label("On target (\(act) vs \(tgt) km/h)", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color(red: 0.12, green: 0.52, blue: 0.28))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.green.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 12))

        case .slow:
            Label("Below target — speed up (\(act) vs \(tgt) km/h)", systemImage: "hare.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.orange.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 12))

        case .fast:
            Label("Above target — ease off (\(act) vs \(tgt) km/h)", systemImage: "tortoise.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func formatDistance(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.2f km", m / 1000) }
        return String(format: "%.1f m", m)
    }

    private func colorForAsym(_ p: Double) -> Color {
        if p >= 12 { return .red }
        if p >= 7  { return .orange }
        return .secondary
    }

    // MARK: - Control

    private func toggle() { isRunning ? stop() : start() }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        sessionStart = Date()
        steps = 0
        stats.reset()
        lastAlertAt = .distantPast
        displaySpeedKmh = 0
        lastCoachZone = .idle
    }

    private func stop() {
        guard isRunning else { return }
        isRunning = false

        // ---- Compute session score ----
        let baseline = BaselineStore.shared.baseline
        let score = GaitScore.compute(
            asymPct: stats.asymPct,
            mlRMS: motion.mlSwayRMS,
            cadenceSPM: motion.cadenceSPM,
            baselineAsym: baseline?.asymStepTimePct,
            baselineMLSway: baseline?.mlSwayRMS
        )

        // ---- Detect gait tags for this session (compare to TARGET) ----
        let metrics = SessionMetrics(
            cadenceSPM: motion.cadenceSPM,
            mlSwayRMS: motion.mlSwayRMS,
            avgStepTime: stats.avgStepTime,
            cvStepTime: stats.stepTimeCV
        )
        let tags = makePatternTags(metrics: metrics, baseline: BaselineStore.shared.target)

        // Persist session
        let s = SessionSummary(
            id: UUID(),
            date: Date(),
            steps: steps,
            cadenceSPM: motion.cadenceSPM,
            mlSwayRMS: motion.mlSwayRMS,
            symmetryScore: score.total,  // reuse existing field
            tags: tags,                   // store machine tags
            avgStepTime: stats.avgStepTime,
            cvStepTime: stats.stepTimeCV,
            asymStepTimePct: stats.asymPct,
            distanceM: motion.distanceM,
            avgSpeedMps: motion.speedMps
        )
        SessionSummaryStore.shared.add(s)
        last = s
    }

    private func reset() {
        guard !isRunning else { return }
        steps = 0
        stats.reset()
    }

    // MARK: - Live deviation alert (ring/haptic)

    private func checkDeviation() {
        let baseline = BaselineStore.shared.baseline
        let ml = motion.mlSwayRMS
        let asym = stats.asymPct

        var shouldAlert = false

        // absolute guardrails
        if asym >= asymWarnPct { shouldAlert = true }
        if ml >= mlWarnAbs { shouldAlert = true }

        // baseline-relative checks
        if let b = baseline {
            if b.asymStepTimePct > 0, asym >= max(12, b.asymStepTimePct * 1.5) { shouldAlert = true }
            if b.mlSwayRMS > 0, ml >= max(mlWarnAbs, b.mlSwayRMS * 1.5) { shouldAlert = true }
        }

        if shouldAlert, Date().timeIntervalSince(lastAlertAt) > alertCooldown {
            lastAlertAt = Date()
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            AudioServicesPlaySystemSound(1007) // short ring
            // (We don’t persist a session here; that happens on Stop.)
        }
    }
}

#Preview { SessionView() }


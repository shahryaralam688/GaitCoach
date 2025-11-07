import SwiftUI
import HealthKit

struct HealthMetricCard: View {
    let metric: HealthKitManager.Metric
    @StateObject private var hk = HealthKitManager.shared
    @State private var isLoading = false
    @State private var errorText: String?

    // Baseline state
    @State private var baselineValue: Double?
    @State private var deltaText: String?
    @State private var arrow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.title)
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }

            // Primary value (today latest)
            Text(hk.formattedValue(for: metric, sample: hk.latestValues[metric]))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .accessibilityLabel("\(metric.title) value")
                .accessibilityValue(hk.formattedValue(for: metric, sample: hk.latestValues[metric]))

            // Subtle trend line
            if let deltaText, let arrow {
                HStack(spacing: 6) {
                    Text(arrow)
                    Text(deltaText)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Trend")
                .accessibilityValue(deltaText)
            }

            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else if !hk.authorizationGranted {
                Button("Connect Health") {
                    Task { await authorizeLoadObserveAndBaseline() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task {
            if hk.authorizationGranted {
                await loadObserveAndBaseline()
            } else {
                await authorizeLoadObserveAndBaseline()
            }
        }
        .onReceive(hk.$latestValues) { _ in
            // When latest updates (background or foreground), recompute delta
            Task { await computeDeltaIfPossible() }
        }
    }

    // MARK: - Flows

    private func authorizeLoadObserveAndBaseline() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await hk.requestAuthorization(for: [metric])
            await loadObserveAndBaseline()
        } catch {
            errorText = "Health access not granted."
        }
    }

    private func loadObserveAndBaseline() async {
        isLoading = true
        defer { isLoading = false }

        // 1) Latest today
        _ = try? await hk.fetchTodayLatest(for: metric)

        // 2) Start background updates
        await hk.startBackgroundDelivery(for: [metric])

        // 3) Fetch 30-day history and compute baseline + delta
        await fetchBaselineAndDelta()
    }

    private func fetchBaselineAndDelta() async {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -30, to: end) ?? Date(timeIntervalSinceNow: -30*24*3600)
        do {
            let samples = try await hk.fetchSamples(for: metric, start: start, end: end)
            let values = samples.map { $0.quantity.doubleValue(for: metric.unit) }
            baselineValue = BaselineService.meanBaseline(values: values)
            await computeDeltaIfPossible()
        } catch {
            // Silent: baseline optional; the card still shows today's value
        }
    }

    private func computeDeltaIfPossible() async {
        guard let baseline = baselineValue,
              let todayVal = hk.numericValue(for: metric, sample: hk.latestValues[metric]) else {
            deltaText = nil
            arrow = nil
            return
        }
        deltaText = BaselineService.formattedDelta(today: todayVal, baseline: baseline, isPercentLike: metric.isPercentLike)
        arrow = BaselineService.trendArrow(today: todayVal, baseline: baseline, isPercentLike: metric.isPercentLike)
    }
}

#if DEBUG
struct HealthMetricCard_Previews: PreviewProvider {
    static var previews: some View {
        HealthMetricCard(metric: .walkingAsymmetryPercentage)
            .padding()
            .previewLayout(.sizeThatFits)
    }
}
#endif


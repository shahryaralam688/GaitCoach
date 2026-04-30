import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject private var settings = UserSettingsStore.shared
    @AppStorage(AgentDebugLog.enabledKey) private var agentLogEnabled = false

    var body: some View {
        List {
            Section("Passive Monitoring") {
                Label("Status: On (uses Health data)", systemImage: "waveform.path.ecg")
                    .foregroundStyle(.secondary)

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Manage Health Permissions…", systemImage: "gearshape")
                }
            }

            Section("Locomotion (no GPS)") {
                Picker("Carry mode", selection: $settings.carryMode) {
                    ForEach(CarryMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                Picker("Surface", selection: $settings.locomotionSurface) {
                    ForEach(LocomotionSurface.allCases) { surf in
                        Text(surf.label).tag(surf)
                    }
                }

                if settings.locomotionSurface == .treadmill {
                    Toggle("Distance from belt speed", isOn: $settings.treadmillDistanceUsesBeltSpeed)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: "Belt speed: %.1f km/h", settings.treadmillBeltSpeedKmh))
                            .font(.subheadline.monospacedDigit())
                        Slider(value: $settings.treadmillBeltSpeedKmh, in: 1...18, step: 0.5)
                    }

                    Text("When belt integration is off, distance uses detected steps × stride on the treadmill.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let K = settings.weinbergK {
                    Text(String(format: "Weinberg K (calibrated): %.4f", K))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Clear Weinberg K") {
                        settings.weinbergK = nil
                    }
                    .foregroundStyle(.red)
                } else {
                    Text("Stride calibration available under Calibration.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Accuracy QA checklist") {
                    Text(IndoorValidationChecklist.allBulletedText())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Target pace (Walk / Run)") {
                Toggle("Pace coaching", isOn: $settings.paceTargetCoachingEnabled)

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "Walk target: %.1f km/h", settings.paceTargetWalkKmh))
                        .font(.subheadline.monospacedDigit())
                    Slider(value: $settings.paceTargetWalkKmh, in: 2.5...9.5, step: 0.5)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "Run target: %.1f km/h", settings.paceTargetRunKmh))
                        .font(.subheadline.monospacedDigit())
                    Slider(value: $settings.paceTargetRunKmh, in: 6...22, step: 0.5)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "On-target band: ±%.0f%%", settings.paceTargetTolerancePct))
                        .font(.subheadline.monospacedDigit())
                    Slider(value: $settings.paceTargetTolerancePct, in: 5...25, step: 1)
                }

                Text("Shown pace uses motion sensors + step length — not GPS. Calibrate stride under Calibration so estimates track your real walk/run.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Toggle("Record motion debug log", isOn: $agentLogEnabled)
                Text("Writes anonymized gait NDJSON locally and optional POST from Walk → Calibration when Mac ingest host is set. Turn off after capture.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Coach") {
                Text("Configure coaching in Onboarding and the Coach tab. More options coming soon.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .gcBackground()
        .listStyle(.insetGrouped)
        .listRowBackground(Color.white)
        .listSectionSpacing(12)
        .navigationTitle("Settings")
        .onAppear { HealthBackground.shared.start() }
    }
}

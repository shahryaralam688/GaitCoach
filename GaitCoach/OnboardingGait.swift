import SwiftUI

private let onboardingGateAccent = Color(red: 39/255, green: 77/255, blue: 67/255)

struct OnboardingGate: View {
    @AppStorage("didOnboard") private var didOnboard = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            OnboardCard(title: "Calibrate",
                        text: "Walk ~60 steps to set your personal baseline.")
            OnboardCard(title: "Your score",
                        text: "We combine rhythm, stability and cadence.")
            OnboardCard(title: "Health data",
                        text: "We read steps & motion to coach you.")
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .overlay(alignment: .bottom) {
            Button {
                didOnboard = true
                dismiss()
            } label: {
                Text("Get started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(onboardingGateAccent)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }
}

private struct OnboardCard: View {
    let title: String, text: String
    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.largeTitle.bold())
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}


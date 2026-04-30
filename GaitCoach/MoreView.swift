import SwiftUI

struct MoreView: View {
    @AppStorage(AgentDebugLog.enabledKey) private var agentLogEnabled = false

    var body: some View {
        NavigationStack {
            List {
                Section("About") {
                    Text("GaitCoach v1.0")
                        .foregroundStyle(.secondary)
                }
                Section("Links") {
                    Link("Privacy", destination: URL(string: "https://example.com/privacy")!)
                    Link("Support", destination: URL(string: "https://example.com/support")!)
                }
                if agentLogEnabled {
                    Section("Developer") {
                        DebugNdjsonShareLink()
                    }
                }
            }
            .navigationTitle("More")
        }
    }
}

#Preview { MoreView() }


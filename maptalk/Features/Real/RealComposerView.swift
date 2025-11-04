import SwiftUI

struct RealComposerView: View {
    @State private var message: String = ""
    @State private var radius: Double = 200

    var body: some View {
        Form {
            Section("Message") {
                TextField("Share a vibe…", text: $message)
            }

            Section("Radius") {
                Slider(value: $radius, in: 50...500, step: 10) {
                    Text("Radius")
                } minimumValueLabel: {
                    Text("50m")
                } maximumValueLabel: {
                    Text("500m")
                }
                Text("Current radius: \(Int(radius))m")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                PrimaryButton(action: {}) {
                    Label("Post Real", systemImage: "bolt.fill")
                }
            }
        }
        .navigationTitle("New Real")
    }
}


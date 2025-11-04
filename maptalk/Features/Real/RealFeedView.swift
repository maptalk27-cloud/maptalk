import SwiftUI

struct RealFeedView: View {
    @StateObject var viewModel: RealViewModel

    var body: some View {
        NavigationStack {
            List(PreviewData.sampleReals) { real in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Real moment")
                        .font(.headline)
                    Text("Expires \(real.expiresAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Real Feed")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(destination: RealComposerView()) {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}


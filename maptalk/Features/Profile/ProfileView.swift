import SwiftUI

struct ProfileView: View {
    @StateObject var viewModel: ProfileViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Footprints") {
                    Text("Ratings: \(PreviewData.sampleRatings.count)")
                    Text("Reals: \(PreviewData.sampleReals.count)")
                }

                Section("Preferences") {
                    Toggle(isOn: .constant(true)) {
                        Text("Anonymous interactions enabled")
                    }
                }
            }
            .navigationTitle("Profile")
        }
    }
}


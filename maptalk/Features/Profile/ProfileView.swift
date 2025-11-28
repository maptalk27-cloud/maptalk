import SwiftUI

struct ProfileView: View {
    @StateObject var viewModel: ProfileViewModel

    var body: some View {
        NavigationStack {
            ProfileHomeView(viewModel: viewModel)
        }
    }
}

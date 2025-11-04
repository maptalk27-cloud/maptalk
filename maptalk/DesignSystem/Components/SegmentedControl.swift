import SwiftUI

struct SegmentedControl: View {
    let options: [String]
    @Binding var selection: Int

    init(options: [String], selection: Binding<Int>) {
        self.options = options
        self._selection = selection
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options.indices, id: \.self) { index in
                Button(options[index]) {
                    selection = index
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(selection == index ? Theme.neonPrimary.opacity(0.2) : .clear, in: .capsule)
                .overlay {
                    Capsule()
                        .stroke(
                            Theme.neonPrimary.opacity(selection == index ? 1 : 0.5),
                            lineWidth: 1
                        )
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial, in: .capsule)
    }
}


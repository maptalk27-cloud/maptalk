import SwiftUI

extension View {
    @ViewBuilder
    func onChangeCompat<Value: Equatable>(
        of value: Value,
        initial: Bool = false,
        _ action: @escaping (Value) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value, initial: initial) { _, newValue in
                action(newValue)
            }
        } else {
            onChange(of: value) { newValue in
                action(newValue)
            }
        }
    }
}

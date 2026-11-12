import SwiftUI
import UIKit

/// Native zoom resolves the current control when opening AND closing, rather
/// than retaining the control/position that originally presented the sheet.
@MainActor
final class MapTalkCardSourceRegistry {
    var selectedID: MapTalkCardTransitionID?
    private final class Reference {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }
    private var views: [MapTalkCardTransitionID: Reference] = [:]

    func register(_ view: UIView, id: MapTalkCardTransitionID) {
        views[id] = Reference(view)
    }

    func unregister(_ view: UIView, id: MapTalkCardTransitionID) {
        if views[id]?.view === view { views[id] = nil }
    }

    func sourceView() -> UIView? {
        guard let selectedID, let view = views[selectedID]?.view,
              view.window != nil, !view.bounds.isEmpty else { return nil }
        return view
    }
}

private struct MapTalkCardSourcesKey: EnvironmentKey {
    static let defaultValue: MapTalkCardSourceRegistry? = nil
}

extension EnvironmentValues {
    var mapTalkCardSources: MapTalkCardSourceRegistry? {
        get { self[MapTalkCardSourcesKey.self] }
        set { self[MapTalkCardSourcesKey.self] = newValue }
    }
}

/// A non-interactive anchor follows the real control's layout, including drag
/// and floating offsets. It never snapshots or caches screen coordinates.
struct MapTalkCardSourceAnchor: UIViewRepresentable {
    let id: MapTalkCardTransitionID
    let registry: MapTalkCardSourceRegistry

    final class Coordinator {
        private var id: MapTalkCardTransitionID?
        private weak var registry: MapTalkCardSourceRegistry?

        func register(_ view: UIView, id: MapTalkCardTransitionID, registry: MapTalkCardSourceRegistry) {
            if self.id != id || self.registry !== registry { unregister(view) }
            self.id = id
            self.registry = registry
            registry.register(view, id: id)
        }

        func unregister(_ view: UIView) {
            if let id { registry?.unregister(view, id: id) }
            id = nil
            registry = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        context.coordinator.register(view, id: id, registry: registry)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.register(view, id: id, registry: registry)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.unregister(view)
    }
}

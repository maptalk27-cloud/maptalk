import MapKit
import SwiftUI
import Testing
import UIKit
@testable import maptalk

/// Exercises real MapKit frames as well as commands: nominal animation timers
/// alone cannot prove that a native camera actually flew to the next place.
/// Run alone so another UI test cannot replace this test's hosted window.
@Suite(.serialized)
@MainActor
struct MapNativeFlightDiagnosticTests {
    @Test
    func honoluluLanaiActualCameraFrames() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let honolulu = CLLocationCoordinate2D(latitude: 21.32272, longitude: -157.91080)
        let lanai = CLLocationCoordinate2D(latitude: 20.79060, longitude: -156.94978)
        let size = scene.coordinateSpace.bounds.size
        let viewport = MapCameraViewport(size: size, topInset: 115, bottomInset: 335)

        for dense in [false, true] {
            let initial = Self.region(honolulu, meters: 30_000)
            let recorder = NativeFlightProbeRecorder(initial: initial)
            let hosting = UIHostingController(rootView: NativeFlightProbeMap(recorder: recorder))
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.windowLevel = .normal + 1
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            defer {
                recorder.controller.cancelActiveTransition()
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKey()
            }

            try await Task.sleep(for: .milliseconds(1_800))
            try #require(!recorder.frames.isEmpty, "The native Map must actually report visible camera frames")
            let neighbors: [CLLocationCoordinate2D]? = dense ? [
                honolulu, .init(latitude: honolulu.latitude + 0.001, longitude: honolulu.longitude),
                lanai, .init(latitude: lanai.latitude + 0.001, longitude: lanai.longitude)
            ] : nil

            for (label, destination) in [("HNL-LNY", lanai), ("LNY-HNL", honolulu)] {
                recorder.begin(label: "\(dense ? "dense" : "normal")-\(label)")
                recorder.controller.handleRegionChange(
                    currentRegion: recorder.latestRegion,
                    targetRegion: Self.region(destination, meters: 3_600),
                    cause: .poi,
                    viewport: viewport,
                    browsingCoordinates: neighbors,
                    cameraPosition: recorder.commandBinding,
                    onRegionUpdate: { recorder.latestRegion = $0 }
                )
                // Includes MapKit's potentially longer native region landing.
                try await Task.sleep(for: .milliseconds(4_200))
                recorder.report()
                recorder.verifyLanding(at: viewport.framed(Self.region(destination,
                    meters: dense ? 800 : 20_000)), routeDistance: honolulu.distance(to: lanai))
            }

            if dense {
                recorder.begin(label: "dense-rapid-reversals")
                for (index, destination) in [lanai, honolulu, lanai, honolulu, lanai, honolulu].enumerated() {
                    recorder.controller.handleRegionChange(currentRegion: recorder.latestRegion,
                        targetRegion: Self.region(destination, meters: 3_600), cause: .poi,
                        viewport: viewport, browsingCoordinates: neighbors,
                        cameraPosition: recorder.commandBinding,
                        onRegionUpdate: { recorder.latestRegion = $0 })
                    if index < 5 { try await Task.sleep(for: .milliseconds(index.isMultiple(of: 2) ? 160 : 420)) }
                }
                try await Task.sleep(for: .milliseconds(4_200))
                recorder.report()
                recorder.verifyLanding(at: viewport.framed(Self.region(honolulu, meters: 800)),
                    routeDistance: honolulu.distance(to: lanai))
            }
        }
    }

    private static func region(_ center: CLLocationCoordinate2D, meters: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: center, latitudinalMeters: meters, longitudinalMeters: meters)
    }

    @Test
    func longDistanceStillUsesOriginalNativeFlight() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let honolulu = CLLocationCoordinate2D(latitude: 21.32272, longitude: -157.91080)
        let seattle = CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321)
        let viewport = MapCameraViewport(size: scene.coordinateSpace.bounds.size,
            topInset: 115, bottomInset: 335)
        let recorder = NativeFlightProbeRecorder(initial: Self.region(honolulu, meters: 800))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .normal + 1
        window.rootViewController = UIHostingController(rootView: NativeFlightProbeMap(recorder: recorder))
        window.makeKeyAndVisible()
        defer {
            recorder.controller.cancelActiveTransition()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(1_800))
        let neighbors = [honolulu, .init(latitude: honolulu.latitude + 0.001, longitude: honolulu.longitude),
                         seattle, .init(latitude: seattle.latitude + 0.001, longitude: seattle.longitude)]
        for (label, destination) in [("HNL-SEA", seattle), ("SEA-HNL", honolulu)] {
            recorder.begin(label: label)
            recorder.controller.handleRegionChange(currentRegion: recorder.latestRegion,
                targetRegion: Self.region(destination, meters: 3_600), cause: .poi,
                viewport: viewport, browsingCoordinates: neighbors,
                cameraPosition: recorder.commandBinding,
                onRegionUpdate: { recorder.latestRegion = $0 })
            // Screen-relative pacing may extend the original cinematic flight
            // by up to 25%; allow its real MapKit landing to finish as well.
            try await Task.sleep(for: .milliseconds(6_000))
            recorder.report()
            recorder.verifyLanding(at: viewport.framed(Self.region(destination, meters: 800)),
                routeDistance: honolulu.distance(to: seattle))
        }
    }
}

@MainActor
private final class NativeFlightProbeRecorder {
    struct Frame {
        let time: CFTimeInterval
        let center: CLLocationCoordinate2D
        let distance: Double
        let pitch: Double
    }

    let controller = MapFlightController()
    let store: MapCameraPositionStore
    var latestRegion: MKCoordinateRegion
    var frames: [Frame] = []
    private var commands: [String] = []
    private var transactions: [String] = []
    private var nativeEvents: [String] = []
    private var startedAt = CACurrentMediaTime()
    private var label = "prepare"

    init(initial: MKCoordinateRegion) {
        store = MapCameraPositionStore(.region(initial))
        latestRegion = initial
    }

    var commandBinding: Binding<MapCameraPosition> {
        Binding(get: { self.store.position }, set: { position, transaction in
            let kind: String
            if let camera = position.camera {
                kind = "camera lat=\(Self.f(camera.centerCoordinate.latitude)) lon=\(Self.f(camera.centerCoordinate.longitude)) height=\(Int(camera.distance))"
            } else if let region = position.region {
                kind = "region lat=\(Self.f(region.center.latitude)) lon=\(Self.f(region.center.longitude)) latSpan=\(Self.f(region.span.latitudeDelta))"
            } else {
                kind = "other"
            }
            self.commands.append("t=\(self.time()) \(kind) visible={\(self.lastFrameDescription)} bindingAnimation=\(String(describing: transaction.animation)) disabled=\(transaction.disablesAnimations)")
            self.store.setCommand(position)
        })
    }

    var nativeBinding: Binding<MapCameraPosition> {
        Binding(get: { self.store.position }, set: { position, transaction in
            self.nativeEvents.append("t=\(self.time()) user=\(position.positionedByUser) animation=\(String(describing: transaction.animation))")
            // Same semantics as MapTalk's native Map binding.
            if position.positionedByUser { self.controller.cancelActiveTransition() }
            self.store.observeNativePosition(position)
        })
    }

    func begin(label: String) {
        self.label = label
        startedAt = CACurrentMediaTime()
        commands.removeAll()
        transactions.removeAll()
        nativeEvents.removeAll()
        frames = frames.last.map { [Frame(time: startedAt, center: $0.center, distance: $0.distance, pitch: $0.pitch)] } ?? []
        print("NATIVE-START \(label) visible={\(lastFrameDescription)}")
    }

    func frame(_ context: MapCameraUpdateContext) {
        controller.observeCamera(region: context.region, camera: context.camera)
        latestRegion = context.region
        frames.append(Frame(time: CACurrentMediaTime(), center: context.camera.centerCoordinate,
            distance: context.camera.distance, pitch: context.camera.pitch))
    }

    func ended(_ context: MapCameraUpdateContext) {
        controller.observeCamera(region: context.region, camera: context.camera)
        controller.observeCameraEnd()
        if !controller.isTransitionInProgress { latestRegion = context.region }
        nativeEvents.append("t=\(time()) end inProgress=\(controller.isTransitionInProgress) visible={\(lastFrameDescription)} endCamera={lat=\(Self.f(context.camera.centerCoordinate.latitude)) lon=\(Self.f(context.camera.centerCoordinate.longitude)) height=\(Int(context.camera.distance))}")
    }

    func transaction(_ transaction: Transaction) {
        transactions.append("t=\(time()) animation=\(String(describing: transaction.animation)) disabled=\(transaction.disablesAnimations)")
    }

    func report() {
        let pairs = zip(frames, frames.dropFirst())
        var maxJump = 0.0
        var maxJumpAt = 0.0
        var maxZoomRatio = 1.0
        var movementPairs = 0
        var firstMovement: CFTimeInterval?
        var lastMovement: CFTimeInterval?
        var totalDistance = 0.0
        var largestSteps: [(Double, String)] = []
        for (a, b) in pairs {
            let jump = CLLocation(latitude: a.center.latitude, longitude: a.center.longitude)
                .distance(from: CLLocation(latitude: b.center.latitude, longitude: b.center.longitude))
            let ratio = max(a.distance, b.distance) / max(1, min(a.distance, b.distance))
            totalDistance += jump
            if jump > maxJump { maxJump = jump; maxJumpAt = b.time - startedAt }
            maxZoomRatio = max(maxZoomRatio, ratio)
            if jump > 1 || abs(a.distance - b.distance) > 1 {
                movementPairs += 1
                firstMovement = firstMovement ?? a.time
                lastMovement = b.time
            }
            largestSteps.append((jump, "t=\(Self.f(b.time - startedAt)) dt=\(Self.f(b.time - a.time)) jumpM=\(Int(jump)) zoomRatio=\(Self.f(ratio)) height=\(Int(b.distance))"))
        }
        let movingDuration = (lastMovement ?? startedAt) - (firstMovement ?? startedAt)
        print("NATIVE-FLIGHT \(label) frames=\(frames.count) movingPairs=\(movementPairs) movingSeconds=\(Self.f(movingDuration)) totalCenterM=\(Int(totalDistance)) maxStepM=\(Int(maxJump)) maxStepAt=\(Self.f(maxJumpAt)) maxZoomRatio=\(Self.f(maxZoomRatio))")
        for event in commands { print("NATIVE-COMMAND \(label) \(event)") }
        for event in transactions.suffix(12) { print("NATIVE-TRANSACTION \(label) \(event)") }
        for event in nativeEvents.suffix(16) { print("NATIVE-EVENT \(label) \(event)") }
        for (_, step) in largestSteps.sorted(by: { $0.0 > $1.0 }).prefix(6) {
            print("NATIVE-LARGEST-STEP \(label) \(step)")
        }
    }

    func verifyLanding(at expected: MKCoordinateRegion, routeDistance: Double) {
        #expect(frames.count >= 2, "Must inspect rendered camera samples, not only commands")
        #expect(controller.pendingLandingRegion == nil, "Flight must finish, not remain blocked at the gate")
        #expect(!controller.hasUnsettledNativeFlight)
        if let last = frames.last {
            #expect(last.center.distance(to: expected.center) < 150, "Latest destination must actually be visible")
        }
        // Ignore sparse samples caused by simulator stalls. Normalize zoom
        // change to the route's full logarithmic range: a globe-to-street
        // landing naturally has larger ratios than an inter-island landing.
        let minimumDistance = max(1, frames.map(\.distance).min() ?? 1)
        let maximumDistance = max(minimumDistance, frames.map(\.distance).max() ?? 1)
        let zoomRange = max(log(2), log(maximumDistance / minimumDistance))
        for (a, b) in zip(frames, frames.dropFirst()) where b.time - a.time < 0.05 {
            #expect(a.center.distance(to: b.center) < routeDistance * 0.25,
                    "A single rendered step must not teleport across most of the route")
            let zoomStep = abs(log(max(1, b.distance) / max(1, a.distance)))
            #expect(zoomStep / zoomRange < 0.25,
                    "A single rendered step must not suddenly switch to the tight landing zoom")
        }
    }

    private var lastFrameDescription: String {
        guard let frame = frames.last else { return "no-frame" }
        return "t=\(Self.f(frame.time - startedAt)) lat=\(Self.f(frame.center.latitude)) lon=\(Self.f(frame.center.longitude)) height=\(Int(frame.distance)) pitch=\(Self.f(frame.pitch))"
    }

    private func time() -> String { Self.f(CACurrentMediaTime() - startedAt) }
    private static func f(_ value: Double) -> String { String(format: "%.4f", value) }
}

@MainActor
private struct NativeFlightProbeMap: View {
    let recorder: NativeFlightProbeRecorder
    @ObservedObject private var store: MapCameraPositionStore

    init(recorder: NativeFlightProbeRecorder) {
        self.recorder = recorder
        self._store = ObservedObject(wrappedValue: recorder.store)
    }

    var body: some View {
        Map(position: recorder.nativeBinding) { }
            .mapStyle(.standard(elevation: .flat))
            .ignoresSafeArea()
            .onMapCameraChange(frequency: .continuous) { recorder.frame($0) }
            .onMapCameraChange(frequency: .onEnd) { recorder.ended($0) }
            .transaction { recorder.transaction($0) }
    }
}

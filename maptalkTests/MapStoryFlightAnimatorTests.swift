import Combine
import CoreLocation
import Foundation
import MapKit
import SwiftUI
import Testing
import UIKit
@testable import maptalk

@Suite(.serialized)
@MainActor
struct MapStoryFlightAnimatorTests {

    @Test
    func flightPacingUsesRelativeScreenDistanceAndStaysGentlyBounded() {
        let spans: [Double] = [0, 0.25, 0.5, 1, 2, 4, 16, 1_000]
        let scales = spans.map {
            MapFlightPacing.durationScale(travelDistance: $0 * 10_000, visibleSpan: 10_000)
        }
        #expect(scales.prefix(3).allSatisfy { $0 == 1 },
                "Moves within half a visible screen retain their original immediate timing")
        #expect(zip(scales, scales.dropFirst()).allSatisfy { $0.0 <= $0.1 })
        #expect(scales.allSatisfy { $0 >= 1 && $0 <= 1.25 })
        #expect(abs(scales[3] - 1.05) < 0.000_001)
        #expect(abs(scales[4] - 1.107_142_857) < 0.000_001)

        let justPastHalfScreen = MapFlightPacing.durationScale(
            travelDistance: 5_000.01, visibleSpan: 10_000)
        #expect(justPastHalfScreen > 1 && justPastHalfScreen < 1.000_001,
                "Crossing the half-screen threshold must not cause a tempo jump")

        let closeView = MapFlightPacing.durationScale(travelDistance: 100_000, visibleSpan: 1_000)
        let wideView = MapFlightPacing.durationScale(travelDistance: 100_000, visibleSpan: 100_000)
        #expect(closeView > wideView,
                "The same route gets slightly more time when departure is zoomed in")
        #expect(abs(MapFlightPacing.durationScale(travelDistance: 20_000, visibleSpan: 10_000)
            - MapFlightPacing.durationScale(travelDistance: 200_000, visibleSpan: 100_000)) < 0.000_001,
                "Equal travel-to-screen proportions should have equal pacing")
        let huge = MapFlightPacing.durationScale(travelDistance: .greatestFiniteMagnitude, visibleSpan: 1)
        #expect(huge.isFinite && huge <= 1.25 && huge > 1.24)
    }

    @Test
    func invalidFlightPacingInputsKeepTheOriginalTiming() {
        let invalidInputs: [(Double, Double)] = [
            (-1, 10_000), (.nan, 10_000), (.infinity, 10_000),
            (100, 0), (100, -1), (100, .nan), (100, .infinity)
        ]
        for (distance, span) in invalidInputs {
            #expect(MapFlightPacing.durationScale(travelDistance: distance, visibleSpan: span) == 1)
        }
    }

    @Test
    func nativeCameraEchoDoesNotPublishAnotherAppCameraCommand() {
        let store = MapCameraPositionStore()
        var commands = 0
        let observation = store.objectWillChange.sink { commands += 1 }
        let camera = MapCamera(centerCoordinate: .init(latitude: 47.72, longitude: -117),
                               distance: 80_000, heading: 0, pitch: 0)
        store.observeNativePosition(.camera(camera))
        #expect(commands == 0, "Native endpoints are observations, not new app commands")
        #expect(store.position.camera?.distance == camera.distance)
        #expect(store.commandBinding.wrappedValue.camera?.centerCoordinate.longitude == -117)
        store.commandBinding.wrappedValue = .camera(camera)
        #expect(commands == 1, "An explicit camera command must still invalidate even at the same stored endpoint")
        store.setCommand(.automatic)
        #expect(commands == 2)
        withExtendedLifetime(observation) {}
    }

    @Test
    func pendingDestinationSurvivesUntilMapKitActuallyFinishes() async throws {
        let controller = MapFlightController()
        let origin = region(latitude: 48.2, longitude: -122.6)
        let store = MapCameraPositionStore(.region(origin))
        controller.handleRegionChange(currentRegion: origin,
            targetRegion: region(latitude: 48.75, longitude: -122.48), cause: .initial,
            cameraPosition: store.commandBinding, onRegionUpdate: { _ in })
        controller.observeCamera(region: region(latitude: 48.2, longitude: -122.6))
        // MapKit can still be landing after the controller's nominal duration.
        try await Task.sleep(for: .milliseconds(650))
        #expect(!controller.isTransitionInProgress)
        #expect(controller.hasUnsettledNativeFlight)
        #expect(controller.pendingLandingRegion != nil,
                "Opening a child during the native landing must still remember its destination")
        controller.observeCameraEnd()
        #expect(controller.hasUnsettledNativeFlight,
                "A late departure onEnd is not proof that the issued landing completed")
        let landing = try #require(store.position.region)
        let stillWide = MKCoordinateRegion(center: landing.center, span: .init(
            latitudeDelta: landing.span.latitudeDelta * 4,
            longitudeDelta: landing.span.longitudeDelta * 4))
        controller.observeCamera(region: stillWide)
        controller.observeCameraEnd()
        #expect(controller.pendingLandingRegion != nil,
                "Even after the nominal timer, a same-center wide cruise cannot finish a landing")
        controller.observeCamera(region: landing)
        controller.observeCameraEnd()
        #expect(!controller.hasUnsettledNativeFlight)
        #expect(controller.pendingLandingRegion == nil)
    }

    @Test(arguments: [false, true])
    func shortDirectLandingEndingBeforeItsTimerDoesNotRemainPending(fitsPortraitViewport: Bool) async throws {
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = region(latitude: 21.32272, longitude: -157.91080)
        let destination = CLLocationCoordinate2D(latitude: 21.32372, longitude: -157.91080)
        let target = MKCoordinateRegion(center: destination,
            latitudinalMeters: 3_600, longitudinalMeters: 3_600)
        let recorder = CameraCommandRecorder(origin: origin)
        var completions = 0
        controller.handleRegionChange(currentRegion: origin, targetRegion: target,
            cause: .poi, browsingCoordinates: [destination,
                .init(latitude: destination.latitude + 0.001, longitude: destination.longitude)],
            cameraPosition: recorder.binding, onRegionUpdate: { _ in completions += 1 })
        let landing = try #require(controller.pendingLandingRegion)
        #expect(controller.isTransitionInProgress)
        #expect(recorder.commands.count == 1)

        // A replaced cruise can end at the right center but at overview zoom.
        // That old callback must not be mistaken for this close-up landing.
        let stillWide = MKCoordinateRegion(center: landing.center, span: .init(
            latitudeDelta: landing.span.latitudeDelta * 40,
            longitudeDelta: landing.span.longitudeDelta * 40))
        controller.observeCamera(region: stillWide, camera: .init(
            centerCoordinate: landing.center, distance: 130_000, heading: 0, pitch: 0))
        controller.observeCameraEnd()
        #expect(controller.hasUnsettledNativeFlight)
        #expect(controller.pendingLandingRegion != nil)
        #expect(controller.isTransitionInProgress)

        // Native MapKit may finish a tiny return before the requested .35 s.
        // On a portrait viewport it expands latitude while retaining the
        // requested longitude scale; that is a genuine fitted completion.
        let fitted = MKCoordinateRegion(center: landing.center, span: .init(
            latitudeDelta: landing.span.latitudeDelta * (fitsPortraitViewport ? 2.2 : 1),
            longitudeDelta: landing.span.longitudeDelta))
        controller.observeCamera(region: fitted, camera: .init(
            centerCoordinate: landing.center, distance: 3_217, heading: 0, pitch: 0))
        controller.observeCameraEnd()
        #expect(!controller.hasUnsettledNativeFlight)
        #expect(controller.pendingLandingRegion == nil)
        #expect(!controller.isTransitionInProgress)

        try await Task.sleep(for: .milliseconds(650))
        #expect(controller.pendingLandingRegion == nil,
                "The later nominal timer must not resurrect pending native completion")
        #expect(!controller.hasUnsettledNativeFlight)
        #expect(!controller.isTransitionInProgress)
        #expect(recorder.commands.count == 1)
        #expect(completions == 1)
    }

    @Test
    func cancelledLegacyFlightCannotOverwriteAUserCameraCommandAfterNativeEcho() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let origin = region(latitude: 47.6, longitude: -122.3)
        let target = region(latitude: 48.45, longitude: -122.3)
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let store = MapCameraPositionStore(.region(origin))
        var commands = 0
        var settledRegions: [MKCoordinateRegion] = []
        let observation = store.objectWillChange.sink { commands += 1 }
        controller.handleRegionChange(
            currentRegion: origin, targetRegion: target, cause: .real,
            cameraPosition: store.commandBinding,
            onRegionUpdate: { settledRegions.append($0) }
        )

        // Wait until the legacy lift has issued its travel command, but before
        // the queued dive. The host then observes and takes over the camera.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while commands < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(commands == 2)
        try #require(controller.pendingLandingRegion != nil)
        #expect(settledRegions.isEmpty)
        let manual = region(latitude: 47.61, longitude: -122.32)
        store.observeNativePosition(.region(manual))
        controller.observeCamera(region: manual)
        #expect(commands == 2, "A native camera observation must not reissue the travel endpoint")

        controller.cancelActiveTransition()
        store.commandBinding.wrappedValue = .region(manual)
        let commandsAfterTakeover = commands
        try await Task.sleep(for: .seconds(1))

        #expect(commands == commandsAfterTakeover,
                "Canceled dive callbacks must not issue an old command after camera takeover")
        let position = try #require(store.position.region)
        #expect(position.center.latitude == manual.center.latitude)
        #expect(position.center.longitude == manual.center.longitude)
        #expect(settledRegions.isEmpty, "A canceled flight cannot publish a stale settled region")
        #expect(controller.pendingLandingRegion == nil)
        #expect(!controller.isTransitionInProgress)
        withExtendedLifetime(observation) {}
    }

    @Test
    func cinematicFlightKeepsOriginalCameraCommandsWithScreenRelativePacing() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        // About 150 km: the original cinematic branch, not a preserve-zoom hop.
        let origin = region(latitude: 47.6, longitude: -122.3)
        let target = region(latitude: 48.95, longitude: -122.3)
        let nearby = CLLocationCoordinate2D(latitude: 48.951, longitude: -122.3)
        let original = MapFlightController()
        let dense = MapFlightController()
        defer {
            original.cancelActiveTransition()
            dense.cancelActiveTransition()
        }
        let originalCommands = CameraCommandRecorder(origin: origin, controller: original)
        let denseCommands = CameraCommandRecorder(origin: origin, controller: dense)
        var originalCompletions = 0
        var denseCompletions = 0
        var originalFinishedAt: ContinuousClock.Instant?
        var denseFinishedAt: ContinuousClock.Instant?

        original.handleRegionChange(currentRegion: origin, targetRegion: target, cause: .poi,
            cameraPosition: originalCommands.binding, onRegionUpdate: { _ in
                originalCompletions += 1
                originalFinishedAt = .now
            })
        dense.handleRegionChange(currentRegion: origin, targetRegion: target, cause: .poi,
            browsingCoordinates: [target.center, nearby],
            cameraPosition: denseCommands.binding, onRegionUpdate: { _ in
                denseCompletions += 1
                denseFinishedAt = .now
            })

        let deadline = ContinuousClock.now.advanced(by: .milliseconds(4_600))
        while (originalCompletions == 0 || denseCompletions == 0), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(originalCommands.commands.count == 3)
        try #require(denseCommands.commands.count == 3)
        #expect(originalCompletions == 1)
        #expect(denseCompletions == 1)

        // Keep the original whole MapKit cameras and 1.5 s lift handoff.
        // Only cruise and landing scale with the route's proportion of the
        // departure view; dense destination framing must not change that pace.
        // A custom Binding's transaction need not expose the ambient animation.
        let expectedLift = origin.center.interpolated(to: target.center, fraction: 0.38)
        let pacing = MapFlightPacing.durationScale(
            travelDistance: origin.center.distance(to: target.center), visibleSpan: 30_000)
        for (commands, finishedAt) in [
            (originalCommands.commands, originalFinishedAt),
            (denseCommands.commands, denseFinishedAt)
        ] {
            for index in 1..<3 {
                let elapsed = commands[index - 1].time.duration(to: commands[index].time)
                let expectedDuration = index == 1 ? 1.5 : 1.5 * pacing
                #expect(elapsed >= .seconds(expectedDuration - 0.05))
                #expect(elapsed < .seconds(expectedDuration + 0.25))
            }
            let finished = try #require(finishedAt)
            let landingDuration = commands[2].time.duration(to: finished)
            #expect(landingDuration >= .seconds(0.2 * pacing - 0.03))
            #expect(landingDuration < .seconds(0.2 * pacing + 0.25))
            let lift = try #require(commands[0].position.camera)
            let cruise = try #require(commands[1].position.camera)
            #expect(abs(lift.centerCoordinate.latitude - expectedLift.latitude) < 0.000_001)
            #expect(abs(lift.centerCoordinate.longitude - expectedLift.longitude) < 0.000_001)
            #expect(lift.distance == 320_000)
            #expect(lift.pitch == 36)
            #expect(lift.heading == 0)
            #expect(cruise.centerCoordinate.latitude == target.center.latitude)
            #expect(cruise.centerCoordinate.longitude == target.center.longitude)
            #expect(cruise.distance == lift.distance)
            #expect(cruise.pitch == lift.pitch)
            #expect(cruise.heading == lift.heading)
        }

        let originalLanding = try #require(originalCommands.commands[2].position.region)
        let denseLanding = try #require(denseCommands.commands[2].position.region)
        let expectedDense = try #require(dense.neighborhoodRegion(for: target,
            coordinates: [target.center, nearby]))
        #expect(originalLanding.center.latitude == target.center.latitude)
        #expect(originalLanding.center.longitude == target.center.longitude)
        #expect(denseLanding.center.latitude == originalLanding.center.latitude)
        #expect(denseLanding.center.longitude == originalLanding.center.longitude)
        #expect(denseLanding.span.latitudeDelta == expectedDense.span.latitudeDelta)
        #expect(denseLanding.span.longitudeDelta == expectedDense.span.longitudeDelta)
        #expect(denseLanding.span.latitudeDelta < originalLanding.span.latitudeDelta / 10,
                "Dense destination framing changes landing scale, not the original route or departure-based pace")
    }

    @Test
    func delayedNativeCruiseCannotLandUntilBothCenterAndHeightArrive() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = MKCoordinateRegion(
            center: .init(latitude: 20.79060, longitude: -156.94978),
            latitudinalMeters: 800, longitudinalMeters: 800)
        let destination = CLLocationCoordinate2D(latitude: 21.32272, longitude: -157.91080)
        let target = MKCoordinateRegion(center: destination,
            latitudinalMeters: 3_600, longitudinalMeters: 3_600)
        let recorder = CameraCommandRecorder(origin: origin)
        var completions = 0
        controller.observeCamera(region: origin, camera: .init(
            centerCoordinate: origin.center, distance: 3_217, heading: 0, pitch: 0))
        controller.handleRegionChange(currentRegion: origin, targetRegion: target,
            cause: .poi, browsingCoordinates: [destination,
                .init(latitude: destination.latitude + 0.001, longitude: destination.longitude)],
            cameraPosition: recorder.binding, onRegionUpdate: { _ in completions += 1 })
        try await waitUntil { recorder.commands.count == 2 }
        let cruise = try #require(recorder.commands.last?.position.camera)

        // Reproduce the reported state after the original .84 s flight budget:
        // MapKit is still near Lanai and only partway out of the close-up.
        controller.observeCamera(region: origin, camera: .init(
            centerCoordinate: origin.center, distance: 32_607, heading: 0, pitch: 0))
        try await Task.sleep(for: .milliseconds(700))
        controller.observeCameraEnd() // An interrupted native animation emits this too.
        #expect(controller.isTransitionInProgress,
                "Nominal time must not release ownership while actual cruise is unfinished")
        #expect(controller.pendingLandingRegion != nil)
        #expect(recorder.commands.count == 2)
        #expect(completions == 0)

        // Neither the right center at the wrong height nor the right height at
        // the departure is permission to switch from camera to region.
        controller.observeCamera(region: target, camera: .init(
            centerCoordinate: destination, distance: cruise.distance / 2, heading: 0, pitch: 0))
        controller.observeCameraEnd()
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.commands.count == 2)
        controller.observeCamera(region: origin, camera: .init(
            centerCoordinate: origin.center, distance: cruise.distance, heading: 0, pitch: 0))
        controller.observeCameraEnd()
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.commands.count == 2)

        for _ in 0..<3 {
            controller.observeCamera(region: target, camera: cruise)
            controller.observeCameraEnd()
        }
        try await waitUntil { completions == 1 }
        #expect(recorder.commands.count == 3,
                "Repeated continuous/end observations must schedule exactly one landing")
        let landing = try #require(recorder.commands.last?.position.region)
        #expect(landing.center.distance(to: destination) < 1)
        #expect(landing.span.latitudeDelta < target.span.latitudeDelta / 2)
        controller.observeCamera(region: target, camera: cruise)
        controller.observeCameraEnd()
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.commands.count == 3)
        #expect(completions == 1)
    }

    @Test
    func replacementCancelsAnAlreadyQueuedNativeLandingAndIgnoresOldEnd() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = region(latitude: 20.79060, longitude: -156.94978)
        let oldTarget = region(latitude: 21.32272, longitude: -157.91080)
        let newTarget = region(latitude: 21.2, longitude: -158.0)
        let recorder = CameraCommandRecorder(origin: origin)
        var completions: [MKCoordinateRegion] = []
        controller.handleRegionChange(currentRegion: origin, targetRegion: oldTarget,
            cause: .poi, cameraPosition: recorder.binding,
            onRegionUpdate: { completions.append($0) })
        try await waitUntil { recorder.commands.count == 2 }
        let oldCruise = try #require(recorder.commands.last?.position.camera)
        try await Task.sleep(for: .milliseconds(550))

        // Readiness queues the safe handoff on the next run loop. A newer
        // swipe arriving first must invalidate even that already-queued work.
        controller.observeCamera(region: oldTarget, camera: oldCruise)
        let replacementStart = recorder.commands.count
        controller.handleRegionChange(currentRegion: oldTarget, targetRegion: newTarget,
            cause: .poi, cameraPosition: recorder.binding,
            onRegionUpdate: { completions.append($0) })
        try await waitUntil { recorder.commands.count >= replacementStart + 2 }
        let newCruise = try #require(recorder.commands.last?.position.camera)
        controller.observeCamera(region: oldTarget, camera: oldCruise)
        controller.observeCameraEnd()
        try await Task.sleep(for: .milliseconds(550))
        #expect(recorder.commands.count == replacementStart + 2)
        #expect(completions.isEmpty, "An old onEnd is not the new destination's completion")
        #expect(controller.isTransitionInProgress)

        controller.observeCamera(region: newTarget, camera: newCruise)
        try await waitUntil { completions.count == 1 }
        let landings = recorder.commands.dropFirst(replacementStart).compactMap { $0.position.region }
        #expect(landings.count == 1)
        let landing = try #require(landings.first)
        #expect(landing.center.distance(to: newTarget.center) < 1)
        #expect(completions.first?.center.longitude == newTarget.center.longitude)
        controller.observeCamera(region: landing)
        controller.observeCameraEnd()
        #expect(controller.pendingLandingRegion == nil)
    }

    @Test
    func missingNativeObservationsReleaseOwnershipWithoutForcingLanding() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = region(latitude: 47.6, longitude: -122.3)
        let target = region(latitude: 48.45, longitude: -122.3)
        let recorder = CameraCommandRecorder(origin: origin)
        var completions = 0
        controller.handleRegionChange(currentRegion: origin, targetRegion: target,
            cause: .poi, cameraPosition: recorder.binding,
            onRegionUpdate: { _ in completions += 1 })
        try await waitUntil { recorder.commands.count == 2 }
        let cruise = try #require(recorder.commands.last?.position.camera)
        try await waitUntil(timeout: .seconds(4)) { controller.pendingLandingRegion == nil }
        #expect(!controller.isTransitionInProgress)
        #expect(!controller.hasUnsettledNativeFlight)
        #expect(recorder.commands.count == 2, "A watchdog must not force the unsafe region jump")
        #expect(completions == 0)

        controller.observeCamera(region: target, camera: cruise)
        controller.observeCameraEnd()
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.commands.count == 2, "Late samples cannot resurrect an abandoned handoff")
        #expect(completions == 0)
    }

    @Test(arguments: [false, true])
    func rendererAdjustedOverviewRequiresNativeEndAndRouteCoverage(crossesDateLine: Bool) async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = crossesDateLine
            ? region(latitude: 21, longitude: 179)
            : region(latitude: 21.32272, longitude: -157.91080)
        let target = crossesDateLine
            ? region(latitude: 21, longitude: -178)
            : region(latitude: 47.6, longitude: -122.3)
        let recorder = CameraCommandRecorder(origin: origin)
        var completions = 0
        controller.handleRegionChange(currentRegion: origin, targetRegion: target,
            cause: .poi, cameraPosition: recorder.binding,
            onRegionUpdate: { _ in completions += 1 })
        try await waitUntil { recorder.commands.count == 2 }
        let cruise = try #require(recorder.commands.last?.position.camera)
        try await Task.sleep(for: .milliseconds(2_000))

        let adjusted = MapCamera(centerCoordinate: cruise.centerCoordinate,
            distance: cruise.distance * 0.78, heading: cruise.heading, pitch: cruise.pitch)
        let overview = MKCoordinateRegion(center: target.center,
            span: .init(latitudeDelta: crossesDateLine ? 20 : 70,
                        longitudeDelta: crossesDateLine ? 20 : 90))
        controller.observeCamera(region: overview, camera: adjusted)
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.commands.count == 2,
                "A different requested height requires a settled native overview, not just a broad sample")

        let incomplete = MapCamera(centerCoordinate: cruise.centerCoordinate,
            distance: cruise.distance * 0.79, heading: cruise.heading, pitch: cruise.pitch)
        controller.observeCamera(region: target, camera: incomplete)
        controller.observeCameraEnd()
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.commands.count == 2,
                "Native onEnd alone cannot accept the right center without enough route overview")

        controller.observeCamera(region: overview, camera: adjusted)
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.commands.count == 2,
                "Moving again invalidates the previous native-ended observation")
        controller.observeCameraEnd()
        try await waitUntil { completions == 1 }
        #expect(recorder.commands.count == 3)
        let landing = try #require(recorder.commands.last?.position.region)
        #expect(landing.center.distance(to: target.center) < 1,
                "A renderer-clamped overview can land without a requested-height special case")
    }

    @Test
    func hemisphereFlightFinishesFromSettledAdjustedDestinationOverview() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let controller = MapFlightController()
        defer { controller.cancelActiveTransition() }
        let origin = region(latitude: -1.2921, longitude: 36.8219) // Nairobi
        let target = region(latitude: 48.117, longitude: -122.76) // Mock BelRed
        let recorder = CameraCommandRecorder(origin: origin)
        var completions = 0
        controller.handleRegionChange(currentRegion: origin, targetRegion: target,
            cause: .poi, cameraPosition: recorder.binding,
            onRegionUpdate: { _ in completions += 1 })
        try await waitUntil { recorder.commands.count == 2 }
        let cruise = try #require(recorder.commands.last?.position.camera)
        try await Task.sleep(for: .milliseconds(2_000))

        // A native globe view centered on North America cannot display Nairobi
        // on the opposite hemisphere, nor must it preserve the requested height.
        let overview = MKCoordinateRegion(center: target.center,
            span: .init(latitudeDelta: 70, longitudeDelta: 90))
        let adjusted = MapCamera(centerCoordinate: target.center,
            distance: cruise.distance * 0.55, heading: cruise.heading, pitch: cruise.pitch)
        controller.observeCamera(region: overview, camera: adjusted)
        controller.observeCameraEnd()
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.commands.count == 2,
                "A clamped view must not bypass the normal arrival gate immediately")

        try await waitUntil(timeout: .seconds(4)) { completions == 1 }
        #expect(recorder.commands.count == 3,
                "The bounded recovery must issue exactly one landing, not leave a continental map")
        let landing = try #require(recorder.commands.last?.position.region)
        #expect(landing.center.distance(to: target.center) < 1)
        #expect(landing.span.latitudeDelta < 1)
        controller.observeCamera(region: landing)
        controller.observeCameraEnd()
        #expect(controller.pendingLandingRegion == nil)
        #expect(!controller.hasUnsettledNativeFlight)
    }

    @Test
    func adjustedOverviewRecoveryCannotOverridePanReplacementOrMovingCamera() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let origin = region(latitude: -1.2921, longitude: 36.8219)
        let target = region(latitude: 48.117, longitude: -122.76)
        let controllers = (0..<3).map { _ in MapFlightController() }
        defer { controllers.forEach { $0.cancelActiveTransition() } }
        let recorders = controllers.map { _ in CameraCommandRecorder(origin: origin) }
        var completions = [0, 0, 0]
        for index in controllers.indices {
            controllers[index].handleRegionChange(currentRegion: origin, targetRegion: target,
                cause: .poi, cameraPosition: recorders[index].binding,
                onRegionUpdate: { _ in completions[index] += 1 })
        }
        try await waitUntil { recorders.allSatisfy { $0.commands.count == 2 } }
        let overview = MKCoordinateRegion(center: target.center,
            span: .init(latitudeDelta: 70, longitudeDelta: 90))
        for index in controllers.indices {
            let cruise = try #require(recorders[index].commands.last?.position.camera)
            controllers[index].observeCamera(region: overview, camera: .init(
                centerCoordinate: target.center, distance: cruise.distance * 0.55,
                heading: cruise.heading, pitch: cruise.pitch))
            controllers[index].observeCameraEnd()
        }

        let manual = region(latitude: 47.61, longitude: -122.32)
        controllers[0].cancelActiveTransition()
        recorders[0].binding.wrappedValue = .region(manual)
        let replacement = region(latitude: 40.7, longitude: -74.0)
        controllers[1].handleRegionChange(currentRegion: overview, targetRegion: replacement,
            cause: .initial, cameraPosition: recorders[1].binding,
            onRegionUpdate: { _ in completions[1] += 1 })
        // A new moving sample invalidates the previous native-ended sample.
        controllers[2].observeCamera(region: overview, camera: .init(
            centerCoordinate: target.center, distance: 21_000_000, heading: 0, pitch: 36))
        let commandCounts = recorders.map { $0.commands.count }
        try await Task.sleep(for: .milliseconds(5_200))

        #expect(recorders.map { $0.commands.count } == commandCounts,
                "Old watchdog callbacks must not resume after takeover or during native motion")
        #expect(completions == [0, 1, 0])
        #expect(recorders[0].commands.last?.position.region?.center.latitude == manual.center.latitude)
        #expect(recorders[1].commands.last?.position.region?.center.latitude == replacement.center.latitude)
        #expect(controllers[2].pendingLandingRegion == nil)
        #expect(!controllers[2].hasUnsettledNativeFlight)
    }

    private func waitUntil(timeout: Duration = .milliseconds(2_500), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Expected camera observation/command did not arrive")
    }

    @MainActor
    private final class CameraCommandRecorder {
        struct Command {
            let position: MapCameraPosition
            let time: ContinuousClock.Instant
        }

        private var position: MapCameraPosition
        private(set) var commands: [Command] = []
        private weak var controller: MapFlightController?

        init(origin: MKCoordinateRegion, controller: MapFlightController? = nil) {
            position = .region(origin)
            self.controller = controller
        }

        var binding: Binding<MapCameraPosition> {
            Binding(get: { self.position }, set: { position in
                self.position = position
                self.commands.append(.init(position: position, time: .now))
                if let camera = position.camera {
                    // Only legacy timing tests opt into an ideal renderer.
                    // Gate regression tests supply delayed real-shaped samples.
                    self.controller?.observeCamera(region: .init(
                        center: camera.centerCoordinate,
                        latitudinalMeters: camera.distance,
                        longitudinalMeters: camera.distance), camera: camera)
                } else if let region = position.region {
                    self.controller?.observeCamera(region: region)
                }
            })
        }
    }

    private func region(latitude: Double, longitude: Double) -> MKCoordinateRegion {
        .init(center: .init(latitude: latitude, longitude: longitude),
              latitudinalMeters: 30_000, longitudinalMeters: 30_000)
    }
}

import Combine
import CoreLocation
import MapKit
import SwiftUI
import Testing
import UIKit
@testable import maptalk

@Suite(.serialized)
@MainActor
struct MapStoryFlightAnimatorTests {

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

    @Test(.timeLimit(.minutes(1)))
    func globalReversalWithChangingAnnotationsDoesNotEchoLandingBeforeAnimation() async throws {
        let viewport = reversalViewport
        let spokane = CLLocationCoordinate2D(latitude: 47.72, longitude: -117)
        let nairobi = CLLocationCoordinate2D(latitude: -1.2921, longitude: 36.8219)
        let initial = MKCoordinateRegion(center: spokane, latitudinalMeters: 20_000,
                                         longitudinalMeters: 20_000)
        let state = StoryFlightMapState(region: viewport.framed(initial), usesController: true)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForInitialFraming(state, viewport: viewport)

        let outward = try beginControllerFlight(state, from: spokane, to: nairobi, viewport: viewport)
        try await Task.sleep(for: .seconds(outward.request.duration * 0.35))
        // Do not run hundreds of synchronous assertions on the main actor
        // while MapKit is still moving: that delays observation callbacks
        // immediately before the reversal we are trying to measure.
        let outwardEndSample = state.samples.count
        let live = try #require(state.latestCamera)
        try #require(live.distance > outward.plan.start.distance * 5,
                     "Reverse a visibly lifted camera, where an early endpoint echo causes a clear zoom flash")
        let reversal = try beginControllerFlight(state, from: nairobi, to: spokane, viewport: viewport)
        #expect(reversal.request.isRetarget)
        try await Task.sleep(for: .milliseconds(220))
        let early = Array(state.samples.dropFirst(reversal.firstSample))
        try #require(early.count > 1)
        #expect(early.allSatisfy { abs(log($0.distance / live.distance)) < 0.35 },
                "Changing the selected annotation must not briefly apply the city-scale binding endpoint before resuming the lifted animation")
        try await Task.sleep(for: .seconds(max(0, reversal.began + reversal.request.duration
                                              - CACurrentMediaTime()) + 0.45))
        try assertGlobalCameraFrames(state, flight: outward, endingBefore: outwardEndSample)
        try assertGlobalCameraFrames(state, flight: reversal)
        try assertGlobalLanding(state, flight: reversal)
        let stableSample = state.samples.count
        try await Task.sleep(for: .milliseconds(400))
        #expect(state.samples.dropFirst(stableSample).allSatisfy {
            $0.centerCoordinate.distance(to: reversal.plan.landing.centerCoordinate) < 100
                && abs($0.distance - reversal.plan.landing.distance) < 150
        })
    }

    @Test(.timeLimit(.minutes(1)))
    func rapidGlobalSwipeBurstPreservesLiveZoomAndLatestHawaiiLanding() async throws {
        let viewport = reversalViewport
        let hawaii = GlobalStoryFlightRoute.hawaiiToWallaWalla.origin
        let wallaWalla = GlobalStoryFlightRoute.hawaiiToWallaWalla.destination
        let nairobi = GlobalStoryFlightRoute.hawaiiToNairobi.destination
        let initial = MKCoordinateRegion(center: hawaii, latitudinalMeters: 20_000,
                                         longitudinalMeters: 20_000)
        let state = StoryFlightMapState(region: viewport.framed(initial), usesController: true)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForInitialFraming(state, viewport: viewport)

        // Begin the abuse burst while already lifted and moving, rather than
        // repeatedly interrupting before the global route's initial hold ends.
        let warmup = try beginControllerFlight(state, from: hawaii, to: wallaWalla, viewport: viewport)
        try #require(warmup.plan.isGlobal)
        try await Task.sleep(for: .seconds(warmup.request.duration * 0.35))
        let burstStart = try #require(state.latestCamera)
        let firstSample = state.samples.count
        let began = CACurrentMediaTime()
        var latestDeadline = warmup.began + warmup.request.duration
        var previous = wallaWalla
        var finalFlight: ObservedControllerFlight?
        let destinations = [hawaii, nairobi, wallaWalla, hawaii, wallaWalla, nairobi, wallaWalla, hawaii]
        for (index, destination) in destinations.enumerated() {
            let flight = try beginControllerFlight(state, from: previous, to: destination, viewport: viewport)
            try #require(flight.plan.isGlobal)
            #expect(flight.request.isRetarget)
            latestDeadline = max(latestDeadline, flight.began + flight.request.duration)
            finalFlight = flight
            previous = destination
            if index < destinations.count - 1 { try await Task.sleep(for: .milliseconds(80)) }
        }
        let final = try #require(finalFlight)
        try await Task.sleep(for: .seconds(final.request.duration + 0.45))
        try assertGlobalCameraFrames(state, flight: final)
        try assertGlobalLanding(state, flight: final)

        let frames = Array(state.samples.dropFirst(firstSample))
        let times = Array(state.sampleTimes.dropFirst(firstSample))
        try #require(frames.count > 20)
        try #require(frames.allSatisfy {
            CLLocationCoordinate2DIsValid($0.centerCoordinate) && $0.distance.isFinite && $0.distance > 0
        })
        var previousCamera = burstStart
        var previousTime = began
        for (camera, time) in zip(frames, times) {
            let elapsed = max(0, time - previousTime)
            #expect(abs(log(camera.distance / previousCamera.distance)) <= 0.045 + 9 * elapsed,
                    "Every rapid global replacement must continue the live perceived zoom")
            #expect(previousCamera.centerCoordinate.distance(to: camera.centerCoordinate)
                    <= max(previousCamera.distance, camera.distance) * 0.08 + 3_000_000 * elapsed + 1_000,
                    "A burst boundary must not jump back to an old departure or ahead to an old destination")
            previousCamera = camera
            previousTime = time
        }
        let stableSample = state.samples.count
        try await Task.sleep(for: .seconds(max(0.6, latestDeadline - CACurrentMediaTime() + 0.4)))
        try assertGlobalLanding(state, flight: final)
        #expect(state.samples.dropFirst(stableSample).allSatisfy {
            $0.centerCoordinate.distance(to: final.plan.landing.centerCoordinate) < 100
                && abs($0.distance - final.plan.landing.distance) < 150
        }, "None of the eight superseded global destinations may return after Hawaii has landed")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0.94, 0.98])
    func globalLateReversalWithChangingAnnotationsKeepsLiveCamera(phase: Double) async throws {
        let viewport = reversalViewport
        let spokane = CLLocationCoordinate2D(latitude: 47.72, longitude: -117)
        let nairobi = CLLocationCoordinate2D(latitude: -1.2921, longitude: 36.8219)
        let initial = MKCoordinateRegion(center: spokane, latitudinalMeters: 20_000,
                                         longitudinalMeters: 20_000)
        let state = StoryFlightMapState(region: viewport.framed(initial), usesController: true)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForInitialFraming(state, viewport: viewport)

        let outward = try beginControllerFlight(state, from: spokane, to: nairobi, viewport: viewport)
        try await Task.sleep(for: .seconds(outward.request.duration * phase))
        // Capture only. Assertions and logging here would delay the very late
        // replacement until after the outgoing flight's ownership expires.
        let outwardEndSample = state.samples.count
        let live = try #require(state.latestCamera)
        let snapshotTime = state.sampleTimes.last ?? CACurrentMediaTime()
        let reversal = try beginControllerFlight(state, from: nairobi, to: spokane, viewport: viewport)
        try await Task.sleep(for: .milliseconds(220))
        let earlyEndSample = state.samples.count
        try await Task.sleep(for: .seconds(max(0, reversal.began + reversal.request.duration
                                              - CACurrentMediaTime()) + 0.45))

        let snapshotPhase = (snapshotTime - outward.began) / outward.request.duration
        let requestPhase = (reversal.began - outward.began) / outward.request.duration
        print("GLOBAL_LATE_REVERSAL requestedPhase=\(phase) snapshotPhase=\(snapshotPhase) requestPhase=\(requestPhase) outwardDuration=\(outward.request.duration) reverseDuration=\(reversal.request.duration) isRetarget=\(reversal.request.isRetarget) snapshotDistance=\(live.distance)")
        try #require(reversal.request.isRetarget && requestPhase >= phase - 0.01 && requestPhase < 1,
                     "Exercise a genuinely unfinished late flight, not a new departure after landing")
        try #require(outward.plan.isGlobal && reversal.plan.isGlobal)
        try assertGlobalCameraFrames(state, flight: outward, endingBefore: outwardEndSample)
        let early = Array(state.samples[reversal.firstSample..<earlyEndSample])
        try #require(early.count > 1)
        #expect(early.allSatisfy { abs(log($0.distance / live.distance)) < 0.35 },
                "A near-landing reversal must start from the live zoom without a sudden scale reset or extra launch")
        #expect(early.allSatisfy {
            $0.centerCoordinate.distance(to: reversal.plan.landing.centerCoordinate) > 100
        }, "The first 220 ms must not expose the reverse destination before flying there")
        try assertGlobalCameraFrames(state, flight: reversal)
        try assertGlobalLanding(state, flight: reversal)
        let stableSample = state.samples.count
        try await Task.sleep(for: .milliseconds(700))
        try assertGlobalLanding(state, flight: reversal)
        #expect(state.samples.dropFirst(stableSample).allSatisfy {
            $0.centerCoordinate.distance(to: reversal.plan.landing.centerCoordinate) < 100
                && abs($0.distance - reversal.plan.landing.distance) < 150
        }, "A late outgoing landing must not reclaim the map after the reverse flight settles")
    }

    @Test(.timeLimit(.minutes(1)), arguments: GlobalStoryFlightRoute.allCases)
    func globalStoryFlightsUseGradualPerceptualZoomInBothDirections(route: GlobalStoryFlightRoute) async throws {
        let viewport = reversalViewport
        let initial = MKCoordinateRegion(center: route.origin, latitudinalMeters: 20_000,
                                         longitudinalMeters: 20_000)
        let state = StoryFlightMapState(region: viewport.framed(initial), usesController: true)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForInitialFraming(state, viewport: viewport)

        var previous = route.origin
        for destination in [route.destination, route.origin] {
            let firstEndCallback = state.endCallbacks
            let flight = try beginControllerFlight(state, from: previous, to: destination, viewport: viewport)
            try #require(flight.plan.isGlobal, "Long-distance and dateline stories must use the production globe strategy")
            try await Task.sleep(for: .seconds(flight.request.duration + 0.45))
            try assertGlobalCameraFrames(state, flight: flight)
            try assertGlobalLanding(state, flight: flight)
            let endCallbackCount = state.endCallbacks - firstEndCallback
            print("GLOBAL_FLIGHT_CALLBACKS route=\(route) ends=\(endCallbackCount)")
            #expect(endCallbackCount <= 3, "A single global flight must not repeatedly trigger settled-map work")
            let stableSample = state.samples.count
            try await Task.sleep(for: .milliseconds(350))
            #expect(state.samples.dropFirst(stableSample).allSatisfy {
                $0.centerCoordinate.distance(to: flight.plan.landing.centerCoordinate) < 100
                    && abs($0.distance - flight.plan.landing.distance) < 150
            }, "The globe flight must not add a final framing correction after landing")
            previous = destination
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: GlobalStoryFlightRoute.allCases)
    func globalStoryFlightReversalKeepsLiveZoomAndRejectsOldLanding(route: GlobalStoryFlightRoute) async throws {
        let viewport = reversalViewport
        let initial = MKCoordinateRegion(center: route.origin, latitudinalMeters: 20_000,
                                         longitudinalMeters: 20_000)
        let state = StoryFlightMapState(region: viewport.framed(initial), usesController: true)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForInitialFraming(state, viewport: viewport)

        let outward = try beginControllerFlight(state, from: route.origin,
                                                to: route.destination, viewport: viewport)
        try #require(outward.plan.isGlobal)
        try await Task.sleep(for: .seconds(outward.request.duration * 0.35))
        let outwardEndSample = state.samples.count
        let live = try #require(state.latestCamera)
        let reversal = try beginControllerFlight(state, from: route.destination,
                                                 to: route.origin, viewport: viewport)
        #expect(reversal.request.isRetarget)
        try #require(reversal.plan.isGlobal)
        try await Task.sleep(for: .seconds(reversal.request.duration + 0.45))
        try assertGlobalCameraFrames(state, flight: outward, endingBefore: outwardEndSample)
        #expect(live.distance > outward.plan.start.distance * 1.2,
                "Reverse during the visible lift, not before the flight starts")
        try assertGlobalCameraFrames(state, flight: reversal)
        try assertGlobalLanding(state, flight: reversal)
        let stableSample = state.samples.count
        try await Task.sleep(for: .milliseconds(600))
        try assertGlobalLanding(state, flight: reversal)
        #expect(state.samples.dropFirst(stableSample).allSatisfy {
            $0.centerCoordinate.distance(to: reversal.plan.landing.centerCoordinate) < 100
                && abs($0.distance - reversal.plan.landing.distance) < 150
        }, "An interrupted global flight must never resume its old destination or zoom")
    }

    @Test(.timeLimit(.minutes(1)))
    func nativeFlightReportsMapBindingOwnershipWrites() async throws {
        let route = StoryReversalRoute.lanaiAirportToHonoluluTerminal
        let viewport = reversalViewport
        let initial = MKCoordinateRegion(center: route.origin, latitudinalMeters: 20_000,
                                         longitudinalMeters: 20_000)
        let state = StoryFlightMapState(region: viewport.framed(initial), usesController: true)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForInitialFraming(state, viewport: viewport)
        let initialUserOwned = state.position.positionedByUser
        let firstWrite = state.mapBindingWrites.count
        let flight = try beginControllerFlight(state, from: route.origin,
                                               to: route.destination, viewport: viewport)
        try await Task.sleep(for: .seconds(flight.request.duration + 0.4))
        try assertContinuousFrames(state, flight: flight)
        try assertSettled(state, flight: flight)
        let writes = state.mapBindingWrites.dropFirst(firstWrite)
        print("FLIGHT_BINDING_DIAGNOSTIC initialUserOwned=\(initialUserOwned) mapWrites=\(writes.count) userOwnedWrites=\(writes.filter(\.positionedByUser).count)")
        // This initial camera was programmatic. Only a real UI drag can prove
        // behavior after stale positionedByUser ownership; setCenter is not a
        // substitute for that gesture and this diagnostic makes no such claim.
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingProductionFlightWithoutBindingWriteStopsAtLiveCamera() async throws {
        let route = StoryReversalRoute.lanaiAirportToHonoluluTerminal
        let viewport = reversalViewport
        let initial = MKCoordinateRegion(center: route.origin, latitudinalMeters: 20_000,
                                         longitudinalMeters: 20_000)
        let state = StoryFlightMapState(region: viewport.framed(initial), usesController: true)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForInitialFraming(state, viewport: viewport)
        let flight = try beginControllerFlight(state, from: route.origin,
                                               to: route.destination, viewport: viewport)
        try await waitUntil {
            guard let camera = state.latestCamera else { return false }
            let progress = projectedProgress(flight.plan.visibleFocus(of: camera), plan: flight.plan)
            return state.samples.count - flight.firstSample > 8 && progress > 0.15 && progress < 0.65
        }

        let live = try #require(state.latestCamera)
        let preceding = try #require(state.samples.dropLast().last)
        // The callback can trail MapKit's current frame. Permit two observed
        // frame deltas, but not continued travel or a jump to either endpoint.
        let positionTolerance = max(100, live.centerCoordinate.distance(to: preceding.centerCoordinate) * 2)
        let distanceTolerance = max(100, abs(live.distance - preceding.distance) * 2)
        let cancelledSample = state.samples.count
        state.controller.cancelActiveTransition()
        #expect(state.controller.storyFlight == nil)
        // Intentionally do not set state.position: exiting without restoring
        // another camera relies on cancellation itself stopping the animator.
        try await Task.sleep(for: .seconds(max(0.5, flight.began + flight.request.duration
                                               - CACurrentMediaTime() + 0.5)))

        let final = try #require(state.latestCamera)
        #expect(state.controller.storyFlight == nil)
        #expect(final.centerCoordinate.distance(to: live.centerCoordinate) <= positionTolerance,
                "Cancelling alone must leave the map at its live position")
        #expect(abs(final.distance - live.distance) <= distanceTolerance,
                "A cancelled flight must not continue lifting or landing")
        #expect(state.samples.dropFirst(cancelledSample).allSatisfy {
            $0.centerCoordinate.distance(to: live.centerCoordinate) <= positionTolerance
                && abs($0.distance - live.distance) <= distanceTolerance
        }, "No superseded keyframe may move the camera after cancellation and its original deadline")
        #expect(flight.plan.visibleFocus(of: final).distance(to: route.destination) > route.distance * 0.2,
                "Cancellation must not silently complete the old destination")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [80, 150, 250])
    func rapidMixedStorySwipeBurstKeepsLatestDestination(intervalMilliseconds: Int) async throws {
        let viewport = reversalViewport
        let shipwreck = StoryReversalRoute.shipwreckToCoastalResort.origin
        let coastal = StoryReversalRoute.shipwreckToCoastalResort.destination
        let inland = StoryReversalRoute.shipwreckToInlandResort.destination
        let lanaiAirport = StoryReversalRoute.lanaiAirportToHonoluluTerminal.origin
        let terminal = StoryReversalRoute.lanaiAirportToHonoluluTerminal.destination
        let honoluluAirport = StoryReversalRoute.honoluluAirportToKonaAirport.origin
        let konaAirport = StoryReversalRoute.honoluluAirportToKonaAirport.destination
        let initial = MKCoordinateRegion(center: shipwreck, latitudinalMeters: 1_200,
                                         longitudinalMeters: 1_200)
        let state = StoryFlightMapState(region: viewport.framed(initial), usesController: true)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForInitialFraming(state, viewport: viewport)

        // Finish with a short hop just after a long reverse. The final flight
        // can settle before superseded long-flight deadlines have elapsed.
        let destinations = [coastal, inland, shipwreck, inland, coastal, lanaiAirport,
                            terminal, lanaiAirport, honoluluAirport, konaAirport,
                            honoluluAirport, terminal]
        let firstSample = state.samples.count
        var previous = shipwreck
        var requests = Set<UUID>()
        var latestDeadline = CACurrentMediaTime()
        var finalFlight: ObservedControllerFlight?
        for (index, destination) in destinations.enumerated() {
            let flight = try beginControllerFlight(state, from: previous, to: destination, viewport: viewport)
            #expect(requests.insert(flight.request.id).inserted)
            if index > 0 { #expect(flight.request.isRetarget) }
            #expect(flight.request.duration.isFinite && flight.request.duration > 0)
            #expect(flight.plan.overviewDistance.isFinite && flight.plan.overviewDistance > 0)
            #expect(flight.plan.centerKeyframes.allSatisfy {
                CLLocationCoordinate2DIsValid($0.coordinate) && $0.duration.isFinite && $0.duration > 0
                    && $0.startVelocity.latitude.isFinite && $0.startVelocity.longitude.isFinite
                    && $0.endVelocity.latitude.isFinite && $0.endVelocity.longitude.isFinite
            }, "Rapid mixed-distance retargets must never produce invalid native keyframes")
            latestDeadline = max(latestDeadline, flight.began + flight.request.duration)
            finalFlight = flight
            previous = destination
            if index < destinations.count - 1 {
                try await Task.sleep(for: .milliseconds(intervalMilliseconds))
            }
        }

        let final = try #require(finalFlight)
        #expect(final.request.duration < 1.3, "The final nearby hop must exercise a shorter ownership window")
        try await Task.sleep(for: .seconds(final.request.duration + 0.4))
        try assertContinuousFrames(state, flight: final)
        try assertSettled(state, flight: final)
        let stableSample = state.samples.count
        let oldDeadlineWait = max(0.5, latestDeadline - CACurrentMediaTime() + 0.4)
        try await Task.sleep(for: .seconds(oldDeadlineWait))
        try assertSettled(state, flight: final)
        #expect(state.samples.dropFirst(stableSample).allSatisfy {
            $0.centerCoordinate.distance(to: final.plan.landing.centerCoordinate) < 50
                && abs($0.distance - final.plan.landing.distance) < 100
        }, "A superseded long flight must not pull the camera back after the latest short hop lands")
        let allFrames = state.samples.dropFirst(firstSample)
        #expect(allFrames.count > destinations.count * 2,
                "A rapid burst must still produce real camera motion, not only final-position updates")
        #expect(allFrames.allSatisfy {
            CLLocationCoordinate2DIsValid($0.centerCoordinate)
                && $0.distance.isFinite && $0.distance > 0
                && $0.heading.isFinite && $0.pitch.isFinite
        })
        #expect(state.cancelledByCameraObservation == 0)
    }

    @Test(.timeLimit(.minutes(1)), arguments: StoryReversalRoute.allCases)
    func regionalStoryFlightsRemainContinuousWhenReversedAfterLanding(route: StoryReversalRoute) async throws {
        let viewport = reversalViewport
        let initialSpan = route.distance > 12_000 ? 20_000.0 : 1_200.0
        let initial = MKCoordinateRegion(center: route.origin, latitudinalMeters: initialSpan,
                                         longitudinalMeters: initialSpan)
        let state = StoryFlightMapState(region: viewport.framed(initial), usesController: true)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForInitialFraming(state, viewport: viewport)

        var previous = route.origin
        var expectedDuration: Double?
        for destination in [route.destination, route.origin, route.destination, route.origin] {
            let flight = try beginControllerFlight(state, from: previous, to: destination, viewport: viewport)
            if let expectedDuration {
                #expect(abs(flight.request.duration - expectedDuration) < 0.001,
                        "Logical endpoints, not card-framed camera centers, must determine reversal timing")
            }
            expectedDuration = flight.request.duration
            try await Task.sleep(for: .seconds(flight.request.duration + 0.4))
            try assertContinuousFrames(state, flight: flight)
            try assertSettled(state, flight: flight)
            let firstLanding = zip(state.samples.dropFirst(flight.firstSample),
                                   state.sampleTimes.dropFirst(flight.firstSample)).first {
                flight.plan.visibleFocus(of: $0.0).distance(to: destination) < 50
            }?.1
            #expect(firstLanding.map { $0 - flight.began > flight.request.duration * 0.65 } == true,
                    "A settled reverse must fly again, not take a contains-region shortcut")

            let progress = state.samples.dropFirst(flight.firstSample).map {
                projectedProgress(flight.plan.visibleFocus(of: $0), plan: flight.plan)
            }
            #expect(progress.allSatisfy { $0 >= -0.02 && $0 <= 1.02 })
            #expect(zip(progress, progress.dropFirst()).allSatisfy { pair in pair.1 >= pair.0 - 0.02 },
                    "Visible focus must not fly toward the destination and then roll backward")
            previous = destination
        }
        #expect(state.cancelledByCameraObservation == 0)
    }

    @Test(.timeLimit(.minutes(1)), arguments: StoryReversalRoute.allCases)
    func regionalStoryFlightsRetargetFromLiveCameraDuringRapidReversals(route: StoryReversalRoute) async throws {
        let viewport = reversalViewport
        let initialSpan = route.distance > 12_000 ? 20_000.0 : 1_200.0
        let initial = MKCoordinateRegion(center: route.origin, latitudinalMeters: initialSpan,
                                         longitudinalMeters: initialSpan)
        let state = StoryFlightMapState(region: viewport.framed(initial), usesController: true)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForInitialFraming(state, viewport: viewport)

        var previous = route.origin
        var interrupted: [(flight: ObservedControllerFlight, endSample: Int, visible: MapCamera)] = []
        for destination in [route.destination, route.origin] {
            let flight = try beginControllerFlight(state, from: previous, to: destination, viewport: viewport)
            try await Task.sleep(for: .milliseconds(250))
            let endSample = state.samples.count
            let visible = try #require(state.latestCamera)
            // Keep adjacent sample boundaries, but do the synchronous assertion
            // work after settling so it cannot delay the next live observation.
            interrupted.append((flight, endSample, visible))
            previous = destination
        }

        let finalFlight = try beginControllerFlight(state, from: previous, to: route.destination, viewport: viewport)
        #expect(finalFlight.request.isRetarget)
        try await Task.sleep(for: .seconds(finalFlight.request.duration + 0.4))
        for sample in interrupted {
            try assertContinuousFrames(state, flight: sample.flight, endingBefore: sample.endSample)
            #expect(sample.visible.centerCoordinate.distance(to: sample.flight.plan.landing.centerCoordinate) > 50,
                    "The reversal must happen during a real flight, not after an immediate endpoint update")
        }
        try assertContinuousFrames(state, flight: finalFlight)
        try assertSettled(state, flight: finalFlight)
        let stableSample = state.samples.count
        try await Task.sleep(for: .milliseconds(500))
        try assertSettled(state, flight: finalFlight)
        #expect(state.samples.dropFirst(stableSample).allSatisfy {
            $0.centerCoordinate.distance(to: finalFlight.plan.landing.centerCoordinate) < 50
                && abs($0.distance - finalFlight.plan.landing.distance) < 100
        }, "No old departure or delayed landing may win after the latest selection has settled")
        #expect(state.cancelledByCameraObservation == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func nativeControllerFlightSurvivesProductionCameraObservation() async throws {
        let origin = camera(latitude: 37.33, longitude: -122.03)
        let state = StoryFlightMapState(camera: origin, usesController: true)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil {
            state.latestCamera.map { $0.centerCoordinate.distance(to: origin.centerCoordinate) < 25 } == true
                && state.latestRegion != nil
        }

        let destination = region(latitude: 37.33, longitude: -122.00)
        let sampleStart = state.samples.count
        let endStart = state.endCallbacks
        let began = CACurrentMediaTime()
        state.controller.handleRegionChange(
            currentRegion: state.latestRegion, targetRegion: destination, cause: .poi,
            storyFocus: .init(landingSpan: 1_200, previousCoordinate: origin.centerCoordinate),
            cameraPosition: Binding(get: { state.position }, set: { state.position = $0 }),
            onRegionUpdate: { _ in }
        )
        let request = try #require(state.controller.storyFlight)
        try await waitUntil { state.samples.count > sampleStart }
        try await Task.sleep(for: .milliseconds(1_500))

        let final = try #require(state.latestCamera)
        #expect(state.cancelledByCameraObservation == 0,
                "Programmatic keyframes must not be mistaken for a user's map gesture")
        #expect(state.controller.storyFlight?.id == request.id,
                "The production continuous observer must not cancel its own flight")
        #expect(state.samples.dropFirst(sampleStart).count > 8,
                "The real map must report a flight rather than a single teleport")
        let firstLanding = zip(state.samples.dropFirst(sampleStart),
                               state.sampleTimes.dropFirst(sampleStart)).first {
            $0.0.centerCoordinate.distance(to: destination.center) < 25
        }?.1
        #expect(firstLanding.map { $0 - began > 0.8 } == true,
                "A published native request must not instantly apply its final camera")
        #expect(state.endCallbacks - endStart <= 3,
                "A native flight must not repeatedly invoke production's expensive settled-camera work; continuous=\(state.samples.count - sampleStart), onEnd=\(state.endCallbacks - endStart)")
        #expect(final.centerCoordinate.distance(to: destination.center) < 50)
    }

    @Test(.timeLimit(.minutes(1)))
    func clearingRequestAndWritingDirectCameraDoesNotResumeOldFlight() async throws {
        let origin = camera(latitude: 37.33, longitude: -122.03)
        let state = StoryFlightMapState(camera: origin)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil {
            state.latestCamera.map { $0.centerCoordinate.distance(to: origin.centerCoordinate) < 25 } == true
        }

        let request = MapStoryFlightRequest(
            destination: region(latitude: 37.33, longitude: -122.00),
            previousCoordinate: origin.centerCoordinate,
            viewport: nil
        )
        state.request = request
        try await waitUntil {
            state.starts.contains { $0.id == request.id }
                && state.latestCamera.map {
                    $0.centerCoordinate.distance(to: origin.centerCoordinate) > 50
                        || abs($0.distance - origin.distance) > 100
                } == true
        }

        let direct = camera(latitude: 34.05, longitude: -118.25)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.request = nil
            state.position = .camera(direct)
        }
        try await waitUntil {
            state.latestCamera.map {
                $0.centerCoordinate.distance(to: direct.centerCoordinate) < 100
                    && abs($0.distance - direct.distance) < 100
            } == true
        }
        let samplesAtDirectLanding = state.samples.count

        // Observe beyond the full 1.2-second flight, not merely the next frame.
        // Camera coordinates do not require downloaded tiles to be rendered.
        try await Task.sleep(for: .milliseconds(1_500))
        let final = try #require(state.latestCamera)
        #expect(final.centerCoordinate.distance(to: direct.centerCoordinate) < 100)
        #expect(abs(final.distance - direct.distance) < 100)
        #expect(state.samples.dropFirst(samplesAtDirectLanding).allSatisfy {
            $0.centerCoordinate.distance(to: direct.centerCoordinate) < 100
                && abs($0.distance - direct.distance) < 100
        }, "The cancelled keyframes must never pull the map back after its direct replacement")
    }

    @Test(.timeLimit(.minutes(1)))
    func replacingFlightReceivesLiveCameraInsteadOfPreviousStartOrDestination() async throws {
        let origin = camera(latitude: 37.33, longitude: -122.03)
        let firstDestination = region(latitude: 37.33, longitude: -122.00)
        let state = StoryFlightMapState(camera: origin)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil {
            state.latestCamera.map { $0.centerCoordinate.distance(to: origin.centerCoordinate) < 25 } == true
        }

        let first = MapStoryFlightRequest(destination: firstDestination,
            previousCoordinate: origin.centerCoordinate, viewport: nil)
        state.request = first
        try await waitUntil {
            state.starts.contains { $0.id == first.id }
                && state.latestCamera.map {
                    $0.centerCoordinate.distance(to: origin.centerCoordinate) > 350
                        && $0.centerCoordinate.distance(to: firstDestination.center) > 350
                } == true
        }

        let replacement = MapStoryFlightRequest(
            destination: region(latitude: 37.345, longitude: -122.012),
            previousCoordinate: firstDestination.center,
            viewport: nil,
            isRetarget: true
        )
        state.request = replacement
        try await waitUntil { state.starts.contains { $0.id == replacement.id } }
        let started = try #require(state.starts.first { $0.id == replacement.id })
        let visibleAtStart = try #require(started.latestObservedCamera)
        #expect(started.camera.centerCoordinate.distance(to: visibleAtStart.centerCoordinate) < 250,
                "The keyframe builder must receive the visible camera, allowing for one observation frame")
        #expect(started.camera.centerCoordinate.distance(to: origin.centerCoordinate) > 200,
                "A replacement must not restart from the previous flight's departure")
        #expect(started.camera.centerCoordinate.distance(to: firstDestination.center) > 200,
                "A replacement must not pretend the previous flight already landed")

        try await Task.sleep(for: .milliseconds(1_500))
        let final = try #require(state.latestCamera)
        #expect(final.centerCoordinate.distance(to: replacement.destination.center) < 100,
                "Only the replacement destination may win after both flight durations have elapsed")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [-3_000.0, -100.0, 100.0, 3_000.0])
    func nearbyFlightKeepsVisibleFocusMonotonicAndSettlesAfterOverview(northwardMeters: Double) async throws {
        let viewport = MapCameraViewport(size: CGSize(width: 320, height: 600),
                                         topInset: 90, bottomInset: 324)
        let previous = region(latitude: 37.33, longitude: -122.03)
        let destination = region(latitude: previous.center.latitude + northwardMeters / 111_320.0,
                                 longitude: previous.center.longitude)
        // Begin with the previous card's actual framing, including its zoom.
        // During the lift the geographic center must move to compensate for
        // the sheet; the focus of the visible map should never reverse.
        let origin = viewport.framed(previous)
        let state = StoryFlightMapState(region: origin)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil {
            guard let fitted = state.initialFramingCamera, let actual = state.latestCamera else { return false }
            return state.mapSize == viewport.size
                && actual.centerCoordinate.distance(to: fitted.centerCoordinate) < 2
                && abs(actual.distance - fitted.distance) < 2
        }

        let request = MapStoryFlightRequest(destination: destination,
            previousCoordinate: previous.center, viewport: viewport)
        let firstSample = state.samples.count
        state.request = request
        try await waitUntil { state.starts.contains { $0.id == request.id } }
        let started = try #require(state.starts.first { $0.id == request.id })
        let plan = started.plan
        let landing = plan.landing
        let initialFocus = plan.visibleFocus(of: started.camera)
        let finalFocus = plan.visibleFocus(of: landing)
        let direction = northwardMeters > 0 ? 1.0 : -1.0
        let travelMeters = (finalFocus.latitude - initialFocus.latitude) * 111_320 * direction
        try #require(initialFocus.distance(to: previous.center) < 15,
                     "Initial focus mismatch: map=\(state.mapSize), startDistance=\(started.camera.distance), landingDistance=\(landing.distance)")
        try #require(finalFocus.distance(to: destination.center) < 15,
                     "The final visible focus must be the destination, not the geographic camera center")
        try #require(abs(travelMeters - abs(northwardMeters)) < 30)
        try #require(landing.centerCoordinate.distance(to: destination.center) > 200,
                     "The raw pin must be clearly beyond the final card-framed center")

        try await Task.sleep(for: .milliseconds(1_500))
        let samples = Array(state.samples.dropFirst(firstSample))
        try #require(samples.count > 5, "Assert the actual native trajectory, not just its last callback")
        let progress = samples.map { camera in
            (plan.visibleFocus(of: camera).latitude - initialFocus.latitude) * 111_320 * direction
        }
        #expect(progress.allSatisfy { $0 >= -5 && $0 <= travelMeters + 5 },
                "Every live visible focus must stay between the departure and the destination")
        #expect(zip(progress, progress.dropFirst()).allSatisfy { pair in pair.1 >= pair.0 - 5 },
                "The actual map's visible focus must not move backward during its descent")
        let peak = try #require(samples.map(\.distance).max())
        #expect(peak > max(started.camera.distance, landing.distance) * 1.1,
                "A real overview must rise above both the starting and landing camera distances")
        let settled = try #require(state.latestCamera)
        #expect(settled.centerCoordinate.distance(to: landing.centerCoordinate) < 15)
        #expect(abs(settled.distance - landing.distance) < 50)
        #expect(plan.visibleFocus(of: settled).distance(to: destination.center) < 15)

        let stableSampleStart = state.samples.count
        try await Task.sleep(for: .milliseconds(350))
        let final = try #require(state.latestCamera)
        #expect(final.centerCoordinate.distance(to: landing.centerCoordinate) < 15)
        #expect(abs(final.distance - landing.distance) < 50)
        #expect(state.samples.dropFirst(stableSampleStart).allSatisfy {
            $0.centerCoordinate.distance(to: landing.centerCoordinate) < 15
                && abs($0.distance - landing.distance) < 50
        }, "No final region correction may disturb the settled camera")
    }

    private var reversalViewport: MapCameraViewport {
        .init(size: CGSize(width: 320, height: 600), topInset: 90, bottomInset: 324)
    }

    private struct ObservedControllerFlight {
        let request: MapStoryFlightRequest
        let plan: MapStoryFlightPlan
        let firstSample: Int
        let began: CFTimeInterval
        let startObservedAt: CFTimeInterval
    }

    private func waitForInitialFraming(_ state: StoryFlightMapState, viewport: MapCameraViewport) async throws {
        try await waitUntil {
            guard let expected = state.initialFramingCamera, let actual = state.latestCamera else { return false }
            return state.cameraForRegion != nil && state.mapSize == viewport.size
                && actual.centerCoordinate.distance(to: expected.centerCoordinate) < 2
                && abs(actual.distance - expected.distance) < 2
        }
    }

    private func beginControllerFlight(_ state: StoryFlightMapState,
                                       from previous: CLLocationCoordinate2D,
                                       to destination: CLLocationCoordinate2D,
                                       viewport: MapCameraViewport) throws -> ObservedControllerFlight {
        let actual = try #require(state.latestCamera)
        let fit = try #require(state.cameraForRegion)
        let firstSample = state.samples.count
        let began = CACurrentMediaTime()
        let startObservedAt = state.sampleTimes.last ?? began
        let oldRequestID = state.controller.storyFlight?.id
        // Real story selection updates parent view state and map annotations
        // in the same action that publishes the replacement camera request.
        state.selectedDestination = destination
        state.controller.handleRegionChange(currentRegion: state.latestRegion,
            targetRegion: MKCoordinateRegion(center: destination, latitudinalMeters: 1_200, longitudinalMeters: 1_200),
            cause: .poi, viewport: viewport,
            storyFocus: .init(landingSpan: 1_200, previousCoordinate: previous),
            cameraPosition: Binding(get: { state.position }, set: { state.position = $0 }),
            onRegionUpdate: { _ in })
        let request = try #require(state.controller.storyFlight,
                                   "Regional story reversals must use the production native animator")
        #expect(request.id != oldRequestID)
        return ObservedControllerFlight(request: request,
            plan: request.plan(from: actual, cameraForRegion: fit), firstSample: firstSample,
            began: began, startObservedAt: startObservedAt)
    }

    private func assertContinuousFrames(_ state: StoryFlightMapState, flight: ObservedControllerFlight,
                                        endingBefore endSample: Int? = nil) throws {
        let end = endSample ?? state.samples.count
        let frames = Array(state.samples[flight.firstSample..<end])
        let times = Array(state.sampleTimes[flight.firstSample..<end])
        try #require(frames.count > 8, "Require actual intermediate MapKit camera frames, not just a final coordinate")
        let initialFocus = flight.plan.visibleFocus(of: flight.plan.start)
        let totalDistance = max(50, initialFocus.distance(to: flight.request.destination.center))
        var previousFocus = initialFocus
        var previousTime = flight.startObservedAt
        for (index, frame) in zip(frames, times).enumerated() {
            let (camera, time) = frame
            let focus = flight.plan.visibleFocus(of: camera)
            // Allow dropped observation frames according to elapsed time, but
            // never accept a next-frame jump to an old start or landing point.
            let elapsed = max(0, time - previousTime)
            let allowance = totalDistance * (0.06 + 6 * elapsed / flight.request.duration) + 50
            let step = previousFocus.distance(to: focus)
            if step > allowance {
                print("REGIONAL_FLIGHT_DISCONTINUITY frame=\(index) elapsed=\(elapsed) sinceRequest=\(time - flight.began) route=\(totalDistance) start=\(initialFocus) previous=\(previousFocus) current=\(focus) camera=\(camera.centerCoordinate) distance=\(camera.distance) step=\(step) allowance=\(allowance)")
            }
            #expect(step <= allowance,
                    "The live visible camera must remain continuous through a new request")
            previousFocus = focus
            previousTime = time
        }
    }

    private func assertSettled(_ state: StoryFlightMapState, flight: ObservedControllerFlight) throws {
        let actual = try #require(state.latestCamera)
        #expect(state.controller.storyFlight?.id == flight.request.id)
        #expect(actual.centerCoordinate.distance(to: flight.plan.landing.centerCoordinate) < 50)
        #expect(abs(actual.distance - flight.plan.landing.distance) < 100)
        #expect(flight.plan.visibleFocus(of: actual).distance(to: flight.request.destination.center) < 50)
    }

    private func assertGlobalCameraFrames(_ state: StoryFlightMapState, flight: ObservedControllerFlight,
                                          endingBefore endSample: Int? = nil) throws {
        let end = endSample ?? state.samples.count
        let frames = Array(state.samples[flight.firstSample..<end])
        let times = Array(state.sampleTimes[flight.firstSample..<end])
        try #require(frames.count > 12, "The globe flight must deliver actual native intermediate frames")
        try #require(frames.allSatisfy {
            CLLocationCoordinate2DIsValid($0.centerCoordinate) && $0.distance.isFinite && $0.distance > 0
                && $0.heading.isFinite && $0.pitch.isFinite
        })
        let peakLimit = max(9_000_000, flight.plan.start.distance, flight.plan.landing.distance)
        #expect(frames.allSatisfy { $0.distance <= peakLimit * 1.015 },
                "A long route must not zoom out far beyond the moderate globe overview")
        var previous = flight.plan.start
        var previousTime = flight.startObservedAt
        let routeDistance = max(1_000, previous.centerCoordinate.distance(to: flight.plan.landing.centerCoordinate))
        var maximumLogStep = 0.0
        for (index, frame) in zip(frames, times).enumerated() {
            let (camera, time) = frame
            let elapsed = max(0, time - previousTime)
            let logStep = abs(log(camera.distance / previous.distance))
            maximumLogStep = max(maximumLogStep, logStep)
            // Log(distance) measures perceived zoom. Meter-based continuity
            // alone misses a first-frame jump from street scale to space.
            #expect(logStep <= 0.045 + 9 * elapsed,
                    "Perceived zoom must rise/fall gradually, including the first frame and a live retarget")
            let centerStep = previous.centerCoordinate.distance(to: camera.centerCoordinate)
            let centerAllowance = routeDistance * (0.025 + 5 * elapsed / flight.request.duration) + 1_000
            if centerStep > centerAllowance {
                print("GLOBAL_FLIGHT_DISCONTINUITY frame=\(index) elapsed=\(elapsed) sinceRequest=\(time - flight.began) route=\(routeDistance) start=\(flight.plan.start.centerCoordinate) previous=\(previous.centerCoordinate) current=\(camera.centerCoordinate) distance=\(camera.distance) step=\(centerStep) allowance=\(centerAllowance)")
            }
            #expect(centerStep <= centerAllowance,
                    "Spherical center movement must remain continuous across longitude wrapping")
            #expect(abs(camera.pitch - flight.plan.start.pitch) < 1,
                    "The long-distance strategy must not add an unwanted tilted-camera phase")
            previous = camera
            previousTime = time
        }
        let earlyRatios = zip(frames, times).filter { $0.1 - flight.began <= 0.15 }.map {
            $0.0.distance / flight.plan.start.distance
        }
        #expect(earlyRatios.allSatisfy { $0 <= 2.8 },
                "The first 150 ms must not suddenly launch from neighborhood scale into a globe view")
        print("GLOBAL_FLIGHT_METRICS frames=\(frames.count) maxLogStep=\(maximumLogStep) initial150msRatio=\(earlyRatios.max() ?? 1) peak=\(frames.map(\.distance).max() ?? 0) duration=\(flight.request.duration)")
    }

    private func assertGlobalLanding(_ state: StoryFlightMapState, flight: ObservedControllerFlight) throws {
        let actual = try #require(state.latestCamera)
        #expect(state.controller.storyFlight?.id == flight.request.id)
        #expect(actual.centerCoordinate.distance(to: flight.plan.landing.centerCoordinate) < 100)
        #expect(abs(actual.distance - flight.plan.landing.distance) < 150)
        // Globe trajectories land at the framed camera directly; applying the
        // flat-plan visible-focus offset here would assert the wrong geometry.
    }

    private func projectedProgress(_ coordinate: CLLocationCoordinate2D, plan: MapStoryFlightPlan) -> Double {
        let point = MKMapPoint(coordinate)
        let dx = plan.endFocus.x - plan.startFocus.x
        let dy = plan.endFocus.y - plan.startFocus.y
        return ((point.x - plan.startFocus.x) * dx + (point.y - plan.startFocus.y) * dy)
            / max(1, dx * dx + dy * dy)
    }

    private func camera(latitude: Double, longitude: Double) -> MapCamera {
        MapCamera(centerCoordinate: .init(latitude: latitude, longitude: longitude),
                  distance: 1_800, heading: 0, pitch: 0)
    }

    private func region(latitude: Double, longitude: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: .init(latitude: latitude, longitude: longitude),
                           latitudinalMeters: 1_200, longitudinalMeters: 1_200)
    }

    private func host(_ state: StoryFlightMapState) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap {
            $0 as? UIWindowScene
        }.first, "These native-map tests require the existing simulator's application host")
        let host = UIHostingController(rootView: StoryFlightMapFixture(state: state))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return window
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "The native map did not reach the expected camera state within six seconds")
    }
}

enum GlobalStoryFlightRoute: CaseIterable {
    case hawaiiToWallaWalla
    case hawaiiToNairobi
    case shortDatelineCrossing

    var origin: CLLocationCoordinate2D {
        switch self {
        case .hawaiiToWallaWalla, .hawaiiToNairobi:
            StoryReversalRoute.lanaiAirportToHonoluluTerminal.origin
        case .shortDatelineCrossing:
            .init(latitude: 20, longitude: 179.4)
        }
    }

    var destination: CLLocationCoordinate2D {
        switch self {
        // Match the public demo geography used by the existing UI fixtures.
        case .hawaiiToWallaWalla: .init(latitude: 46.065, longitude: -118.343)
        case .hawaiiToNairobi: .init(latitude: -1.2921, longitude: 36.8219)
        // Explicitly synthetic dateline control; not an account record.
        case .shortDatelineCrossing: .init(latitude: 20, longitude: -179.4)
        }
    }
}

// Public landmark geometry only; no account records, media, identifiers or
// local metadata paths belong in these reproducible runtime regressions.
enum StoryReversalRoute: CaseIterable {
    case shipwreckToCoastalResort
    case lanaiAirportToHonoluluTerminal
    case shipwreckToInlandResort
    case honoluluAirportToKonaAirport
    // Synthetic >120 km control, not a claim about any account's Kona post.
    case interIslandDistanceControl

    var origin: CLLocationCoordinate2D {
        switch self {
        case .shipwreckToCoastalResort, .shipwreckToInlandResort:
            .init(latitude: 20.91196, longitude: -156.89678)
        case .lanaiAirportToHonoluluTerminal:
            .init(latitude: 20.79060, longitude: -156.94978)
        case .honoluluAirportToKonaAirport:
            .init(latitude: 21.33147, longitude: -157.92001)
        case .interIslandDistanceControl:
            .init(latitude: 21.33, longitude: -157.92)
        }
    }

    var destination: CLLocationCoordinate2D {
        switch self {
        case .shipwreckToCoastalResort: .init(latitude: 20.74155, longitude: -156.89643)
        case .lanaiAirportToHonoluluTerminal: .init(latitude: 21.32272, longitude: -157.91080)
        case .shipwreckToInlandResort: .init(latitude: 20.83567, longitude: -156.91731)
        case .honoluluAirportToKonaAirport: .init(latitude: 19.73698, longitude: -156.04092)
        case .interIslandDistanceControl: .init(latitude: 19.70, longitude: -156.00)
        }
    }

    var distance: CLLocationDistance { origin.distance(to: destination) }
}

@MainActor
private final class StoryFlightMapState: ObservableObject {
    struct BindingWrite {
        let time: CFTimeInterval
        let positionedByUser: Bool
    }

    struct Start {
        let id: UUID
        let camera: MapCamera
        let plan: MapStoryFlightPlan
        let latestObservedCamera: MapCamera?
    }

    @Published var request: MapStoryFlightRequest?
    @Published var selectedDestination: CLLocationCoordinate2D?
    let initialPosition: MapCameraPosition
    var cameraBinding: Binding<MapCameraPosition>?
    var position: MapCameraPosition {
        get { cameraBinding?.wrappedValue ?? initialPosition }
        set { cameraBinding?.wrappedValue = newValue }
    }
    let controller = MapFlightController()
    let usesController: Bool
    // Instrumentation must not publish a SwiftUI update on every camera frame.
    var latestCamera: MapCamera?
    var latestRegion: MKCoordinateRegion?
    var cancelledByCameraObservation = 0
    var endCallbacks = 0
    var samples: [MapCamera] = []
    var sampleTimes: [CFTimeInterval] = []
    var starts: [Start] = []
    var mapSize: CGSize = .zero
    var mapSafeAreaInsets = EdgeInsets()
    let initialRegion: MKCoordinateRegion?
    var initialFramingCamera: MapCamera?
    var cameraForRegion: ((MKCoordinateRegion) -> MapCamera)?
    // Only native Map -> Binding writes, not controller -> @State commands.
    var mapBindingWrites: [BindingWrite] = []

    init(camera: MapCamera, usesController: Bool = false) {
        initialPosition = .camera(camera)
        initialRegion = nil
        self.usesController = usesController
    }

    init(region: MKCoordinateRegion, usesController: Bool = false) {
        initialPosition = .region(region)
        initialRegion = region
        self.usesController = usesController
    }

    func alignInitialFramingIfNeeded(cameraForRegion: (MKCoordinateRegion) -> MapCamera) {
        guard initialFramingCamera == nil, let initialRegion else { return }
        // A preceding story lands with this exact conversion, not .region's
        // potentially different automatic fitting. Do this once after the
        // native map reports its first live camera and has a usable proxy.
        let fitted = cameraForRegion(initialRegion)
        initialFramingCamera = fitted
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { position = .camera(fitted) }
    }

    func plan(for request: MapStoryFlightRequest, from camera: MapCamera,
              cameraForRegion: (MKCoordinateRegion) -> MapCamera) -> MapStoryFlightPlan {
        let plan = request.plan(from: camera, cameraForRegion: cameraForRegion)
        starts.append(.init(id: request.id, camera: camera, plan: plan,
                            latestObservedCamera: latestCamera))
        return plan
    }

    func observe(_ camera: MapCamera) {
        latestCamera = camera
        samples.append(camera)
        sampleTimes.append(CACurrentMediaTime())
    }
}

private struct StoryFlightMapFixture: View {
    @ObservedObject var state: StoryFlightMapState
    @ObservedObject private var controller: MapFlightController
    @StateObject private var positionStore: MapCameraPositionStore
    @State private var settledCamera: MapCamera?
    @State private var settledRegion: MKCoordinateRegion?

    init(state: StoryFlightMapState) {
        self.state = state
        _controller = ObservedObject(wrappedValue: state.controller)
        _positionStore = StateObject(wrappedValue: MapCameraPositionStore(state.initialPosition))
    }

    var body: some View {
        MapReader { proxy in
            let observedPosition = Binding<MapCameraPosition>(
                get: { positionStore.position },
                set: { newPosition in
                    state.mapBindingWrites.append(.init(time: CACurrentMediaTime(),
                                                        positionedByUser: newPosition.positionedByUser))
                    if state.usesController && newPosition.positionedByUser {
                        controller.cancelActiveTransition()
                    }
                    // Production records native endpoint echoes without
                    // publishing a parent update that sends them back as commands.
                    positionStore.observeNativePosition(newPosition)
                }
            )
            let map = Map(position: observedPosition) {
                if state.usesController, let destination = state.selectedDestination {
                    Annotation("Selected story", coordinate: destination) {
                        Circle().fill(.cyan).frame(width: 22, height: 22)
                            .id(controller.storyFlight?.id)
                    }
                    MapCircle(center: destination, radius: 1_000)
                        .foregroundStyle(.cyan.opacity(0.15))
                }
            }
            Group {
                if state.usesController {
                    map.modifier(MapStoryFlightModifier(controller: state.controller, proxy: proxy))
                } else {
                    map.mapCameraKeyframeAnimator(trigger: state.request?.id) { live in
                        storyFlightKeyframes(state.request.map { request in
                            state.plan(for: request, from: live,
                                       cameraForRegion: { proxy.camera(framing: $0) })
                        })
                    }
                }
            }
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear {
                                state.mapSize = geometry.size
                                state.mapSafeAreaInsets = geometry.safeAreaInsets
                            }
                            .onChange(of: geometry.size) { _, size in
                                state.mapSize = size
                                state.mapSafeAreaInsets = geometry.safeAreaInsets
                            }
                    }
                }
                .ignoresSafeArea()
                .accessibilityValue("\(settledCamera?.centerCoordinate.latitude ?? 0),\(settledRegion?.center.longitude ?? 0)")
                .onAppear {
                    state.cameraBinding = positionStore.commandBinding
                    state.cameraForRegion = { proxy.camera(framing: $0) }
                }
                .onMapCameraChange(frequency: .continuous) { context in
                    state.observe(context.camera)
                    state.latestRegion = context.region
                    if state.usesController {
                        state.controller.observeCamera(region: context.region)
                        // This is the production condition from MapTalkView
                        // while a person's story is active. It must not classify
                        // native keyframes as a user's map gesture.
                        if state.position.positionedByUser {
                            let activeRequest = state.controller.storyFlight?.id
                            state.controller.cancelPendingCameraSteps()
                            if let activeRequest, state.controller.storyFlight?.id != activeRequest {
                                state.cancelledByCameraObservation += 1
                            }
                        }
                    }
                    state.alignInitialFramingIfNeeded(cameraForRegion: { proxy.camera(framing: $0) })
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    state.endCallbacks += 1
                    // Keep the raw callback count, but match production's
                    // suppression of an interrupted animation's early onEnd.
                    if state.usesController && controller.isStoryFlightInProgress { return }
                    settledCamera = context.camera
                    settledRegion = context.region
                }
        }
    }
}

import Foundation
import Testing
@testable import maptalk

@MainActor
struct BackendPlaceHistoryFailureTests {
    @Test
    func verifiedHistorySurvivesOnlyMediaOrTransportFailures() {
        let recoverable: [Error] = [
            BackendClientError.message("Couldn't connect to MapTalk."),
            BackendClientError.http(status: 408, message: "Timeout"),
            BackendClientError.http(status: 429, message: "Retry later"),
            BackendClientError.http(status: 503, message: "Unavailable"),
            URLError(.networkConnectionLost),
            CocoaError(.fileReadCorruptFile)
        ]
        for error in recoverable {
            #expect(BackendStore.canRetainVerifiedPlaceHistory(after: error, hasVerifiedMetadata: true,
                requestRevision: 3, currentRevision: 3, isActive: true))
        }
    }

    @Test
    func accessFailuresNeverRetainEvenPreviouslyVerifiedHistory() {
        let denied: [Error] = [
            BackendClientError.unauthorized,
            BackendClientError.http(status: 401, message: "Expired"),
            BackendClientError.http(status: 403, message: "Revoked"),
            BackendClientError.http(status: 404, message: "Not found", code: "place_unavailable"),
            BackendClientError.http(status: 404, message: "Unknown route"),
            BackendClientError.http(status: 410, message: "Removed"),
            BackendClientError.http(status: 422, message: "Invalid request"),
            CancellationError()
        ]
        for error in denied {
            #expect(!BackendStore.canRetainVerifiedPlaceHistory(after: error, hasVerifiedMetadata: true,
                requestRevision: 3, currentRevision: 3, isActive: true))
        }
    }

    @Test
    func missingMetadataSignoutOrRevisionChangeForbidsKeepingSnapshotForAnyFailure() {
        let error = BackendClientError.message("Couldn't connect to MapTalk.")
        #expect(!BackendStore.canRetainVerifiedPlaceHistory(after: error, hasVerifiedMetadata: false,
            requestRevision: 3, currentRevision: 3, isActive: true))
        #expect(!BackendStore.canRetainVerifiedPlaceHistory(after: error, hasVerifiedMetadata: true,
            requestRevision: 3, currentRevision: 4, isActive: true))
        #expect(!BackendStore.canRetainVerifiedPlaceHistory(after: error, hasVerifiedMetadata: true,
            requestRevision: 3, currentRevision: 3, isActive: false))
    }
}

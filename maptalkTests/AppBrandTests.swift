import Foundation
import Testing
@testable import maptalk

struct AppBrandTests {
    @Test
    func installedDisplayNameMatchesTheInAppBrand() {
        #expect(AppBrand.name == "MapFlick")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == AppBrand.name)
        #expect(AppBrand.wordmark == AppBrand.name.lowercased())
        #expect(AppBrand.tagline == "Your life. Directed by you.")
    }

    @Test
    func permissionPromptsUseTheNewName() throws {
        for key in ["NSLocationWhenInUseUsageDescription", "NSCameraUsageDescription", "NSMicrophoneUsageDescription"] {
            let text = try #require(Bundle.main.object(forInfoDictionaryKey: key) as? String)
            #expect(text.contains(AppBrand.name))
            #expect(!text.contains("MapTalk"))
        }
    }

    @Test
    func rebrandPreservesTheExistingAppIdentity() {
        #expect(Bundle.main.bundleIdentifier == "com.chengsi.maptalk"
            || Bundle.main.bundleIdentifier == "com.chengsi.maptalk.postpoc")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "maptalk")
        #expect(Bundle.main.object(forInfoDictionaryKey: "MapTalkBackendURL") != nil)
    }
}

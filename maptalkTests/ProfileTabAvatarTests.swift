import Combine
import SwiftUI
import Testing
import UIKit
@testable import maptalk

@Suite(.serialized)
@MainActor
struct ProfileTabAvatarTests {
    @Test
    func avatarKeepsItsPhotoColorsAndCircularAspectFillCrop() throws {
        let avatar = ProfileTabAvatar.image(from: sourcePhoto())

        #expect(avatar.size == CGSize(width: 30, height: 30))
        #expect(avatar.renderingMode == .alwaysOriginal)
        let pixels = try rgbaPixels(of: avatar)
        // A wide photo must fill the circle, not squash its red/blue edges into it.
        for point in [(5, 15), (15, 15), (24, 15)] {
            expectGreenPixel(pixels, x: point.0, y: point.1)
        }
        #expect(pixels[3] == 0, "The corner outside the avatar circle must stay transparent")
    }

    @Test(.timeLimit(.minutes(1)))
    func tabBarKeepsAvatarOriginalWhenSelectedAndUnselected() async throws {
        let avatar = ProfileTabAvatar.image(from: sourcePhoto())
        let state = AvatarTabFixtureState()
        let host = UIHostingController(rootView: AvatarTabFixture(state: state))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        var tabController: UITabBarController?
        for _ in 0..<50 {
            host.view.layoutIfNeeded()
            tabController = findTabController(in: host)
            if tabController?.tabBar.items?.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let tabs = try #require(tabController)
        let items = try #require(tabs.tabBar.items)
        #expect(items.count == 2)
        #expect(items.last?.image?.isSymbolImage == true)

        // Production initially displays person.circle, then replaces it after the
        // authenticated photo finishes loading. Exercise that metadata update too.
        state.avatar = avatar
        for _ in 0..<50 {
            host.view.layoutIfNeeded()
            if tabs.tabBar.items?.last?.image?.isSymbolImage == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let profileItem = try #require(tabs.tabBar.items?.last)
        #expect(profileItem.image?.isSymbolImage == false)

        tabs.selectedIndex = 0
        let unselectedImage = try #require(profileItem.image)
        #expect(unselectedImage.renderingMode == .alwaysOriginal,
                "The UIKit tab bridge must not tint the photo black")
        expectGreenPixel(try rgbaPixels(of: unselectedImage), x: 15, y: 15)

        tabs.selectedIndex = 1
        tabs.view.layoutIfNeeded()
        let selectedImage = try #require(profileItem.selectedImage ?? profileItem.image)
        #expect(selectedImage.renderingMode == .alwaysOriginal)
        expectGreenPixel(try rgbaPixels(of: selectedImage), x: 15, y: 15)
    }

    private func sourcePhoto() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 90, height: 30), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
            UIColor.green.setFill()
            context.fill(CGRect(x: 30, y: 0, width: 30, height: 30))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 60, y: 0, width: 30, height: 30))
        }
    }

    private func rgbaPixels(of image: UIImage) throws -> [UInt8] {
        let cgImage = try #require(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: 30 * 30 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 30, height: 30,
                bitsPerComponent: 8, bytesPerRow: 30 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 30, height: 30))
        }
        return pixels
    }

    private func expectGreenPixel(_ pixels: [UInt8], x: Int, y: Int) {
        let offset = (y * 30 + x) * 4
        #expect(pixels[offset] < 20)
        #expect(pixels[offset + 1] > 235)
        #expect(pixels[offset + 2] < 20)
        #expect(pixels[offset + 3] > 235)
    }

    private func findTabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let tabs = findTabController(in: child) { return tabs }
        }
        return nil
    }
}

@MainActor
private final class AvatarTabFixtureState: ObservableObject {
    @Published var avatar: UIImage?
}

private struct AvatarTabFixture: View {
    @ObservedObject var state: AvatarTabFixtureState

    var body: some View {
        TabView {
            Color.clear
                .tabItem { Label("MapTalk", systemImage: "map") }
            Color.clear
                .tabItem {
                    Label {
                        Text("Me")
                    } icon: {
                        profileTabIcon
                    }
                    .labelStyle(.iconOnly)
                }
        }
        .tint(.black)
    }

    // Keep a concrete Image at the tab metadata boundary, as AppRouter does.
    private var profileTabIcon: Image {
        if let avatar = state.avatar {
            return Image(uiImage: avatar).renderingMode(.original)
        }
        return Image(systemName: "person.circle")
    }
}

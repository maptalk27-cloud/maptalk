// swift-tools-version: 6.0
import PackageDescription

// Thin packaging only: the executable binary is Tencent's unmodified official
// no-payment SDK, pinned by SHA-256. There is no third-party auth implementation.
let package = Package(
    name: "MapTalkWeChatSDK",
    platforms: [.iOS(.v15)],
    products: [.library(name: "MapTalkWeChatSDK", targets: ["MapTalkWeChatSDK"])],
    targets: [
        .binaryTarget(
            name: "WechatOpenSDK",
            url: "https://dldir1.qq.com/WechatWebDev/opensdk/XCFramework/OpenSDK2.0.9_NoPay.zip",
            checksum: "ae8c7e847d83997f38891e27ad6bed98dd50d638a00ef2ec0890d4e9ac748f83"
        ),
        .target(
            name: "MapTalkWeChatSDK",
            dependencies: ["WechatOpenSDK"],
            resources: [.copy("PrivacyInfo.xcprivacy")],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("WebKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreTelephony"),
                .linkedFramework("CFNetwork"),
                .linkedLibrary("z"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)

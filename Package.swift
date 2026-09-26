// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HeadFocus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HeadFocus",
            path: "Sources/HeadFocus",
            linkerSettings: [
                .linkedFramework("CoreMotion"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)

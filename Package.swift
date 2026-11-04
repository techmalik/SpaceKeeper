// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpaceKeeper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SpaceKeeper",
            path: "Sources/SpaceKeeper",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)

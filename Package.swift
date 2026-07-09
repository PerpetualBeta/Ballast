// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ballast",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Ballast",
            path: "Sources",
            // Stay in the Swift 5 language mode: the vendored JorvikKit and the
            // app are written against it, and we don't want Swift 6 strict
            // concurrency turning warnings into build errors. Tools 6.0 is only
            // needed for the .macOS(.v15) platform (Synchronization.Atomic).
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-framework", "AppKit"]),
                .unsafeFlags(["-framework", "ServiceManagement"]),
                .unsafeFlags(["-framework", "CoreAudio"]),
                .unsafeFlags(["-framework", "Metal"]),
                .unsafeFlags(["-framework", "MetalKit"]),
                .unsafeFlags(["-framework", "Accelerate"]),
            ]
        )
    ]
)

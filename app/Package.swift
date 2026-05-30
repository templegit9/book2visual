// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Book2Visual",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Book2VisualCore", targets: ["Book2VisualCore"]),
        .executable(name: "Book2VisualApp", targets: ["Book2VisualApp"])
    ],
    targets: [
        // All SwiftUI views, services, view models, models. Type-checks headless.
        .target(
            name: "Book2VisualCore",
            path: "Sources/Book2VisualCore"
        ),
        // Thin @main entry point that hosts the SwiftUI App from the library.
        .executableTarget(
            name: "Book2VisualApp",
            dependencies: ["Book2VisualCore"],
            path: "Sources/Book2VisualApp"
        ),
        .testTarget(
            name: "Book2VisualCoreTests",
            dependencies: ["Book2VisualCore"],
            path: "Tests/Book2VisualCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)

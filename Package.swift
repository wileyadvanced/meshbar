// swift-tools-version: 5.9
import PackageDescription

// MeshBarCore is plain Foundation plus the system sqlite3 library, so it
// builds on Linux for unit tests. The SwiftUI app target is macOS-only.

var products: [Product] = [
    .library(name: "MeshBarCore", targets: ["MeshBarCore"]),
]

var targets: [Target] = []

var coreDependencies: [Target.Dependency] = []

#if os(Linux)
    targets.append(
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        )
    )
    coreDependencies.append("CSQLite")
#endif

targets.append(contentsOf: [
    .target(
        name: "MeshBarCore",
        dependencies: coreDependencies,
        path: "Sources/MeshBarCore"
    ),
    .testTarget(
        name: "MeshBarCoreTests",
        dependencies: ["MeshBarCore"],
        path: "Tests/MeshBarCoreTests",
        resources: [.copy("Fixtures")]
    ),
])

#if os(macOS)
    products.append(.executable(name: "MeshBar", targets: ["MeshBar"]))
    targets.append(
        .executableTarget(
            name: "MeshBar",
            dependencies: ["MeshBarCore"],
            path: "Sources/MeshBar"
        )
    )
#endif

let package = Package(
    name: "MeshBar",
    platforms: [
        .macOS(.v14),
    ],
    products: products,
    targets: targets
)

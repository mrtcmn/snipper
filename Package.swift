// swift-tools-version: 6.2
import PackageDescription

// Snipper is a macOS 26 app. `SnipperCore` is plain Foundation so its logic
// (storage, parsing, ranking) can also be built and tested on Linux.

var products: [Product] = [
    .library(name: "SnipperCore", targets: ["SnipperCore"]),
]

var targets: [Target] = [
    // Only used on Linux, where the SQLite3 module is not part of the SDK.
    .systemLibrary(
        name: "CSQLite",
        path: "Sources/CSQLite",
        providers: [.apt(["libsqlite3-dev"])]
    ),
    .target(
        name: "SnipperCore",
        dependencies: [
            .target(name: "CSQLite", condition: .when(platforms: [.linux])),
        ]
    ),
    .testTarget(
        name: "SnipperCoreTests",
        dependencies: ["SnipperCore"]
    ),
]

#if os(macOS)
products.append(.executable(name: "Snipper", targets: ["Snipper"]))
targets.append(
    .executableTarget(
        name: "Snipper",
        dependencies: ["SnipperCore"],
        // Copied into Snipper.app/Contents/Resources by scripts/build-app.sh.
        exclude: ["Resources"]
    )
)
#endif

let package = Package(
    name: "Snipper",
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)

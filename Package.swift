// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "crate",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CrateCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "cratectl",
            dependencies: ["CrateCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Crate",
            dependencies: ["CrateCore"],
            resources: [.copy("Resources/AppIcon.icns")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CrateCoreTests",
            dependencies: ["CrateCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

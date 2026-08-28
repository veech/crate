// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "djhero",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "DJHeroCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "djheroctl",
            dependencies: ["DJHeroCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DJHero",
            dependencies: ["DJHeroCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

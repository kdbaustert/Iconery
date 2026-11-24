// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Iconery",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Updates. A binary XCFramework, so build.sh copies it into Contents/Frameworks, adds the
        // rpath that finds it there, and signs it before the app.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Iconery",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Iconery",
            // Swift 6 language mode. The library and every view live on the main actor. The one
            // exception is a drag or copy of many icons, which draws and writes its files on
            // every core: each work item gets plain values and its own image, and touches no
            // library state. Strict checking is what proves that stays true, so a later change
            // that hands main-actor state to those threads fails to compile.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IconeryTests",
            dependencies: ["Iconery"],
            path: "Tests/IconeryTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

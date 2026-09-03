// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Konishi",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "Konishi",
            path: "Sources/Konishi",
            linkerSettings: [
                // Embed Info.plist so TCC can read mic/speech usage strings when run via `swift run`.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ]),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "KonishiTests",
            dependencies: ["Konishi"]
        )
    ]
)

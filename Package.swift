// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CricutBT",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "cricut-bt", targets: ["CricutBT"]),
        .executable(name: "StickerSend", targets: ["StickerSend"]),
    ],
    targets: [
        .executableTarget(name: "CricutBT"),
        // The GUI drives the `cricut-bt` binary as a child process, so the
        // hardware-proven print path is used unchanged.
        .executableTarget(name: "StickerSend"),
    ]
)

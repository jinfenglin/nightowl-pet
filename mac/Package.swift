// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeskPet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DeskPet", path: "Sources/DeskPet")
    ]
)

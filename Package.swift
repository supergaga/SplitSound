// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SplitSound",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SplitSound", targets: ["SplitSound"])
    ],
    targets: [
        .executableTarget(name: "SplitSound")
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pave",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PaveKit", targets: ["PaveKit"]),
        .executable(name: "pavectl", targets: ["pavectl"]),
        .executable(name: "PaveAgent", targets: ["PaveAgent"]),
        .executable(name: "Pave", targets: ["Pave"]),
    ],
    targets: [
        .target(name: "PaveKit"),
        .executableTarget(name: "pavectl", dependencies: ["PaveKit"]),
        .executableTarget(name: "PaveAgent", dependencies: ["PaveKit"]),
        .executableTarget(name: "Pave", dependencies: ["PaveKit"]),
        .testTarget(name: "PaveKitTests", dependencies: ["PaveKit"]),
    ]
)

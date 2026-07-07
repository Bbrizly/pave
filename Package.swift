// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacroStudio",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacroEngineKit", targets: ["MacroEngineKit"]),
        .executable(name: "macroctl", targets: ["macroctl"]),
        .executable(name: "MacroStudioAgent", targets: ["MacroStudioAgent"]),
        .executable(name: "MacroStudio", targets: ["MacroStudio"]),
    ],
    targets: [
        .target(name: "MacroEngineKit"),
        .executableTarget(name: "macroctl", dependencies: ["MacroEngineKit"]),
        .executableTarget(name: "MacroStudioAgent", dependencies: ["MacroEngineKit"]),
        .executableTarget(name: "MacroStudio", dependencies: ["MacroEngineKit"]),
        .testTarget(name: "MacroEngineKitTests", dependencies: ["MacroEngineKit"]),
    ]
)

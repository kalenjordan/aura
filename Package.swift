// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Aura",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Aura", targets: ["Aura"])
    ],
    targets: [
        .executableTarget(name: "Aura")
    ]
)

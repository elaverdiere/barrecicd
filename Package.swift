// swift-tools-version: 6.0
import PackageDescription

// ZERO third-party dependencies, per S001 §2. A menu-bar indicator that cannot start because a
// package server is unreachable would be reporting on its own supply chain instead of on CI.
let package = Package(
    name: "barrecicd",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "barrecicd", targets: ["barrecicd"]),
        .library(name: "BarreCore", targets: ["BarreCore"]),
    ],
    targets: [
        // Everything that decides anything. No AppKit, no network, no clock of its own — the whole
        // point of S001 §6: the defects this tool already shipped were all in the derivation, and a
        // derivation you can call from a test is a derivation you can prove.
        .target(name: "BarreCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The thin AppKit shell. It owns the NSMenu — which is the entire reason this exists.
        .executableTarget(name: "barrecicd", dependencies: ["BarreCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BarreCoreTests", dependencies: ["BarreCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

// swift-tools-version: 5.9
//
// aparte-secrets for Swift: finds passwords, API keys, tokens and private keys
// in text, on-device, offline. Same model file and same spans as the JavaScript
// runtime (@aparte/secrets on npm) and the Python reference.

import PackageDescription

let package = Package(
    name: "AparteSecrets",
    platforms: [
        .iOS(.v13), .macOS(.v10_15), .tvOS(.v13), .watchOS(.v6), .visionOS(.v1),
    ],
    products: [
        // The runtime and the int8 model (196 KB), ready to use.
        .library(name: "AparteSecrets", targets: ["AparteSecrets"]),
    ],
    targets: [
        .target(
            name: "AparteSecrets",
            resources: [.copy("Resources/secrets-v1.1-int8.bin")]
        ),
        .testTarget(name: "AparteSecretsTests", dependencies: ["AparteSecrets"]),
    ]
)

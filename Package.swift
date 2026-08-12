// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MyFluidVoice",
    platforms: [
        .macOS("15.0"),
    ],
    dependencies: [
        .package(url: "https://github.com/altic-dev/FluidAudio.git", branch: "B/cohere-coreml-asr"),
        .package(url: "https://github.com/altic-dev/DynamicNotchKit.git", branch: "main"),
        .package(url: "https://github.com/altic-dev/transcribe-cpp-swift.git", exact: "0.1.2"),
        .package(url: "https://github.com/ejbills/mediaremote-adapter", branch: "master"),
    ],
    targets: [
        .target(
            name: "CoreAudioCaptureSupport",
            path: "Sources/CoreAudioCaptureSupport",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
            ]
        ),
        .executableTarget(
            name: "MyFluidVoice",
            dependencies: [
                "CoreAudioCaptureSupport",
                "FluidAudio",
                "DynamicNotchKit",
                .product(name: "TranscribeCpp", package: "transcribe-cpp-swift"),
                .product(name: "MediaRemoteAdapter", package: "mediaremote-adapter"),
            ],
            path: "Sources/Fluid",
            exclude: [
                "CoreAudioCaptureSupportBridge.c",
                "CoreAudioCaptureSupportBridge.h",
                "Fluid-Bridging-Header.h",
            ],
            resources: [
                .process("Assets.xcassets"),
                .process("Resources"),
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-default-isolation=MainActor",
                    "-enable-upcoming-feature", "DisableOutwardActorInference",
                    "-enable-upcoming-feature", "GlobalActorIsolatedTypesUsability",
                    "-enable-upcoming-feature", "InferIsolatedConformances",
                    "-enable-upcoming-feature", "InferSendableFromCaptures",
                    "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
                    "-enable-upcoming-feature", "MemberImportVisibility",
                ]),
            ]
        ),
    ]
)

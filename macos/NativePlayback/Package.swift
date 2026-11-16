// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "PlezyNativePlayback",
  platforms: [.macOS(.v15)],
  products: [
    // Keep Aether's FFmpeg references out of the executable containing mpv's static FFmpeg.
    .library(name: "PlezyNativePlayback", type: .dynamic, targets: ["PlezyNativePlayback"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/superuser404notfound/AetherEngine",
      revision: "29943fdccd1fb900f3414219440a32094eb3e410",
      traits: ["DualLayerDolbyVision", "TrueHDObjectAudio"]
    )
  ],
  targets: [
    .target(
      name: "PlezyNativePlayback",
      dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]
    ),
    .testTarget(name: "PlezyNativePlaybackTests", dependencies: ["PlezyNativePlayback"]),
  ]
)

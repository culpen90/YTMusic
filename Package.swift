// swift-tools-version: 5.10

import PackageDescription

let package = Package(
  name: "YTMusic",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "YTMusic", targets: ["YTMusic"])
  ],
  targets: [
    .executableTarget(
      name: "YTMusic",
      path: "Sources/YTMusic",
      resources: [
        .process("Resources")
      ]
    ),
    .testTarget(
      name: "YTMusicTests",
      dependencies: ["YTMusic"],
      path: "Tests/YTMusicTests"
    ),
  ]
)

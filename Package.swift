// swift-tools-version: 5.10

import PackageDescription

let package = Package(
  name: "Liltfinch",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "Liltfinch", targets: ["Liltfinch"])
  ],
  targets: [
    .executableTarget(
      name: "Liltfinch",
      path: "Sources/Liltfinch",
      resources: [
        .process("Resources")
      ]
    ),
    .testTarget(
      name: "LiltfinchTests",
      dependencies: ["Liltfinch"],
      path: "Tests/LiltfinchTests"
    ),
  ]
)

// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "OpenPlan",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "OpenPlan", targets: ["OpenPlan"])
  ],
  targets: [
    .executableTarget(
      name: "OpenPlan",
      path: "Sources/OpenPlan",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    )
  ]
)

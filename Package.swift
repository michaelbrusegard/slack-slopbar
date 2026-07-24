// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "SlackMenubar",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "SlackMenubarCore", targets: ["SlackMenubarCore"]),
    .executable(name: "SlackMenubar", targets: ["SlackMenubar"]),
  ],
  targets: [
    .target(
      name: "SlackMenubarCore"
    ),
    .executableTarget(
      name: "SlackMenubar",
      dependencies: ["SlackMenubarCore"]
    ),
    .testTarget(
      name: "SlackMenubarCoreTests",
      dependencies: ["SlackMenubarCore"]
    ),
  ]
)

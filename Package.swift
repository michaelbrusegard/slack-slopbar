// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "SlackSlopbar",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "SlackSlopbarCore", targets: ["SlackSlopbarCore"]),
    .executable(name: "SlackSlopbar", targets: ["SlackSlopbar"]),
  ],
  targets: [
    .target(
      name: "SlackSlopbarCore"
    ),
    .executableTarget(
      name: "SlackSlopbar",
      dependencies: ["SlackSlopbarCore"]
    ),
    .testTarget(
      name: "SlackSlopbarCoreTests",
      dependencies: ["SlackSlopbarCore"]
    ),
  ]
)

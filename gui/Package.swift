// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "IMUMenuBar",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "IMUMenuBarCore", targets: ["IMUMenuBarCore"]),
    .executable(name: "IMUMenuBar", targets: ["IMUMenuBar"])
  ],
  targets: [
    .target(
      name: "IMUMenuBarCore",
      linkerSettings: [.linkedFramework("Contacts")]
    ),
    .executableTarget(name: "IMUMenuBar", dependencies: ["IMUMenuBarCore"]),
    .testTarget(name: "IMUMenuBarCoreTests", dependencies: ["IMUMenuBarCore"])
  ]
)

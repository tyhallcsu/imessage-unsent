// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "IMUDaemon",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "IMUCore", targets: ["IMUCore"]),
    .executable(name: "imu-watcher", targets: ["imu-watcher"])
  ],
  targets: [
    .target(name: "IMUCore"),
    .executableTarget(name: "imu-watcher", dependencies: ["IMUCore"]),
    .testTarget(name: "IMUCoreTests", dependencies: ["IMUCore"])
  ]
)

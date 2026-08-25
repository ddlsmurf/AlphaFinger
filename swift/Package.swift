// swift-tools-version: 5.9
import PackageDescription

// No external dependencies: CoreBluetooth is system-provided, and everything
// else here is byte manipulation.
let package = Package(
  name: "AlphaFingerKit",
  platforms: [.macOS(.v13), .iOS(.v16)],
  products: [
    .library(name: "AlphaFingerKit", targets: ["AlphaFingerKit"]),
    .executable(name: "AlphaFinger", targets: ["AlphaFinger"]),
  ],
  targets: [
    .target(name: "AlphaFingerKit"),
    .executableTarget(name: "AlphaFinger", dependencies: ["AlphaFingerKit"]),
    .testTarget(name: "AlphaFingerKitTests", dependencies: ["AlphaFingerKit"]),
  ]
)

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "EsuissRelayGenerator",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.3")
  ],
  targets: []
)

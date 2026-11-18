// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "EsuissRelay",
  defaultLocalization: "en",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [
    .library(name: "EsuissRelay", targets: ["EsuissRelay"]),
    .library(name: "EsuissRelayUI", targets: ["EsuissRelayUI"]),
    .library(
      name: "EsuissRelayNotificationService",
      targets: ["EsuissRelayNotificationService"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.3"),
    .package(url: "https://github.com/apple/swift-openapi-urlsession", exact: "1.4.0"),
    .package(url: "https://github.com/apple/swift-http-types", exact: "1.8.0"),
  ],
  targets: [
    .target(
      name: "EsuissRelayAPI",
      dependencies: [
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
      ]
    ),
    .target(
      name: "EsuissRelay",
      dependencies: [
        "EsuissRelayAPI",
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
      ]
    ),
    .target(
      name: "EsuissRelayUI",
      dependencies: ["EsuissRelay"],
      resources: [.process("Resources")]
    ),
    .target(
      name: "EsuissRelayNotificationService",
      dependencies: ["EsuissRelay"]
    ),
    .testTarget(
      name: "EsuissRelayTests",
      dependencies: [
        "EsuissRelay",
        "EsuissRelayAPI",
        "EsuissRelayUI",
        "EsuissRelayNotificationService",
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
      ]
    ),
  ],
  swiftLanguageModes: [.v5]
)

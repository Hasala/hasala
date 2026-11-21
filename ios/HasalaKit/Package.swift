// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "HasalaKit",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "HasalaModels", targets: ["HasalaModels"]),
    .library(name: "HasalaDesign", targets: ["HasalaDesign"]),
    .library(name: "HasalaMocks", targets: ["HasalaMocks"]),
    .library(name: "HasalaWidgetData", targets: ["HasalaWidgetData"]),
  ],
  targets: [
    .target(name: "HasalaModels"),
    .target(
      name: "HasalaDesign",
      dependencies: ["HasalaModels"],
      resources: [.copy("Fonts")]
    ),
    .target(name: "HasalaMocks", dependencies: ["HasalaModels"]),
    .target(name: "HasalaWidgetData", dependencies: ["HasalaModels"]),
    .testTarget(
      name: "HasalaKitTests", dependencies: ["HasalaModels", "HasalaDesign", "HasalaMocks", "HasalaWidgetData"]),
  ]
)

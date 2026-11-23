// swift-tools-version: 6.2
import Foundation
import PackageDescription

let kit = ProcessInfo.processInfo.environment["HASALA_KIT_PATH"] ?? "../../../HasalaKit"

let package = Package(
  name: "SampleSeedExport",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(path: "../.."),
    .package(path: kit),
  ],
  targets: [
    .testTarget(
      name: "SampleSeedExportTests",
      dependencies: [
        .product(name: "CoreDomain", package: "HasalaCore"),
        .product(name: "CoreCategorize", package: "HasalaCore"),
        .product(name: "CoreJSON", package: "HasalaCore"),
        .product(name: "CorePrimitives", package: "HasalaCore"),
        .product(name: "CoreResources", package: "HasalaCore"),
        .product(name: "CoreTime", package: "HasalaCore"),
        .product(name: "CoreWire", package: "HasalaCore"),
        .product(name: "HasalaModels", package: "HasalaKit"),
        .product(name: "HasalaMocks", package: "HasalaKit"),
      ],
      path: "Tests/SampleSeedExportTests"),
  ],
  swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.2
import PackageDescription

let l0: [Target.Dependency] = [
  "CorePrimitives", "HasalaText", "CoreJSON", "CoreTime", "CoreMoney", "CoreResources",
]
let l1: [Target.Dependency] = ["CoreWire", "CoreCrypto", "CoreAuth", "CoreNorm", "CoreTemplate", "CoreExtract", "CoreMail"]
let l2: [Target.Dependency] = ["CoreReplay", "CoreInvariants", "CoreCategorize", "CoreDomain"]
let l3: [Target.Dependency] = ["CoreStore", "CoreProjection"]
let l4: [Target.Dependency] = ["CoreSync", "CoreOutbox", "CoreMailbox", "CoreSignals"]

let ordered: Target.Dependency = .product(name: "OrderedCollections", package: "swift-collections")
let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")

func core(
  _ name: String, _ dir: String, _ deps: [Target.Dependency] = [],
  resources: [Resource]? = nil
) -> Target {
  .target(name: name, dependencies: deps, path: "Sources/HasalaCore/\(dir)", resources: resources)
}

let libraries = [
  "CorePrimitives", "HasalaText", "CoreJSON", "CoreTime", "CoreMoney", "CoreResources",
  "CoreWire", "CoreCrypto", "CoreAuth", "CoreNorm", "CoreTemplate", "CoreExtract", "CoreMail",
  "CoreReplay", "CoreInvariants", "CoreCategorize", "CoreDomain",
  "CoreStore", "CoreProjection",
  "CoreSync", "CoreOutbox", "CoreMailbox", "CoreSignals",
  "HasalaModel", "HasalaKeychain", "CoreTestSupport", "CoreSoftAuth", "HasalaCloud",
]
let unitTested = libraries.filter { $0 != "CoreResources" && $0 != "CoreTestSupport" }

let testDependencies: [String: [Target.Dependency]] = [
  "CoreDomain": ["CoreTestSupport"],
  "CoreProjection": ["CoreTestSupport", "CoreInvariants"],
  "CoreSync": ["CoreTestSupport"],
  "CoreOutbox": ["CoreTestSupport"],
  "CoreMailbox": ["CoreTestSupport"],
  "CoreSoftAuth": ["CoreCrypto"],
]

let package = Package(
  name: "HasalaCore",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: libraries.map { .library(name: $0, targets: [$0]) },
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    .package(url: "https://github.com/apple/swift-collections", exact: "1.7.2"),
  ],
  targets: [
    core("CorePrimitives", "Primitives"),
    core("HasalaText", "Text"),
    core("CoreJSON", "JSON", ["HasalaText"]),
    core("CoreTime", "Time"),
    core("CoreMoney", "Money", ["HasalaText"]),
    core(
      "CoreResources", "Resources",
      resources: [
        .copy("templates"), .copy("sample"), .copy("merchant-dictionary.json"), .copy("common-passwords-v1.txt"),
      ]),

    core("CoreWire", "Wire", l0),
    core("CoreCrypto", "Crypto", l0 + ["CoreWire"]),
    core("CoreAuth", "Auth", l0),
    core("CoreNorm", "Norm", l0),
    core("CoreTemplate", "Template", l0 + ["HasalaICU"]),
    core("CoreExtract", "Extract"),
    core("CoreMail", "Mail", l0),

    core("CoreReplay", "Replay", l0 + ["CoreWire", ordered]),
    core("CoreInvariants", "Invariants", ["CoreReplay", "CoreWire", "CoreCrypto"]),
    core("CoreCategorize", "Categorize", l0 + [ordered]),
    core("CoreDomain", "Domain", l0 + ["CoreWire", "CoreReplay", "CoreCategorize", ordered]),

    core("CoreStore", "Store", l0 + l1 + l2 + [grdb, ordered]),
    core("CoreProjection", "Projection", l0 + ["CoreWire", "CoreReplay", "CoreDomain", "CoreCategorize", grdb, ordered]),

    core("CoreSync", "Sync", l0 + l1 + l2 + l3),
    core("CoreOutbox", "Outbox", ["CoreSync"]),
    core("CoreMailbox", "Mailbox", l0 + l1 + l2 + l3 + ["CoreOutbox", "CoreSync"]),
    core("CoreSignals", "Signals", ["CoreDomain", "CoreProjection", ordered]),

    core("HasalaModel", "Model", ["CoreCategorize"]),
    core("HasalaKeychain", "Keychain", ["CorePrimitives", "CoreStore"]),
    core("HasalaCloud", "Cloud", ["CoreCategorize"]),

    .systemLibrary(name: "HasalaICU", path: "Sources/HasalaICU"),

    core("CoreTestSupport", "TestSupport", l0 + l1 + l2 + l3 + l4),
    core("CoreSoftAuth", "SoftAuth", ["CorePrimitives", "CoreAuth"]),

    .testTarget(
      name: "HasalaCoreConformanceTests",
      dependencies: l0 + ["CoreWire", "CoreCrypto", "CoreNorm", "CoreTemplate", "CoreExtract", "CoreMail"]
        + ["CoreReplay", "CoreInvariants", "CoreCategorize", "CoreDomain", "CoreSoftAuth"],
      path: "Tests/HasalaCoreConformanceTests"),
    .testTarget(
      name: "HasalaCoreE2ETests",
      dependencies: [
        "CoreSync", "CoreAuth", "CoreSoftAuth", "CoreTestSupport", "CoreDomain", "CoreReplay", "CoreInvariants",
        "CoreCategorize", "CoreProjection", "CoreOutbox", "CoreMailbox", "CoreTemplate",
      ],
      path: "Tests/HasalaCoreE2ETests"),
  ]
    + unitTested.map { name in
      .testTarget(
        name: "\(name)Tests", dependencies: [.byName(name: name)] + (testDependencies[name] ?? []),
        path: "Tests/\(name)Tests")
    },
  swiftLanguageModes: [.v6]
)

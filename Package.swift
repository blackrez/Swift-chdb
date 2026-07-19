// swift-tools-version: 6.3

import PackageDescription

#if os(macOS) && arch(arm64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-macos-arm64.artifactbundle.zip",
    checksum: "6e4f50abb25aa1902f677d8fc477b9dd682d72bedafecba6dff1953804449e2f"
)
#elseif os(macOS) && arch(x86_64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-macos-x86_64.artifactbundle.zip",
    checksum: "6cb84da5f31696be3b1bc811186c9093cb8fcc750f1c3fe925df3934dc3c0804"
)
#elseif os(Linux) && arch(x86_64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-linux-x86_64.artifactbundle.zip",
    checksum: "424af64424dc3b17fa6e02960a39e2c851d08ef979cdd898d841e7d9f235c398"
)
#elseif os(Linux) && arch(arm64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-linux-aarch64.artifactbundle.zip",
    checksum: "94a58a8f1d606698fe1862f9e911b66e67ff40b41695c5cf915c9df35ed34721"
)
#endif

let products: [Product] = [
    .library(name: "Swift-chdb", targets: ["Swift-chdb"]),
    .library(name: "ClickhouseNative", targets: ["ClickhouseNative"]),
    .executable(name: "chdb-repl", targets: ["ChdbRepl"]),
    .executable(name: "chdb-native-demo", targets: ["ChdbNativeDemo"]),
    .executable(name: "chdb-stream-demo", targets: ["ChdbStreamDemo"]),
    .executable(name: "chdb-clickbench", targets: ["ChdbClickBench"]),
    .executable(name: "chdb-clickbench-native", targets: ["ChdbClickBenchNative"]),
]

let targets: [Target] = [
    chdbTarget,
    .target(name: "Cclickhouse"),
    .target(name: "Swift-chdb", dependencies: ["Cchdb", "ClickhouseNative", .product(name: "NIOPosix", package: "swift-nio")]),
    .target(name: "ClickhouseNative", dependencies: ["Cclickhouse"]),
    .executableTarget(name: "ChdbRepl", dependencies: ["Swift-chdb"], path: "Examples/ChdbRepl"),
    .executableTarget(name: "ChdbNativeDemo", dependencies: ["Swift-chdb", "ClickhouseNative"], path: "Examples/ChdbNativeDemo"),
    .executableTarget(name: "ChdbStreamDemo", dependencies: ["Swift-chdb", "ClickhouseNative"], path: "Examples/ChdbStreamDemo"),
    .executableTarget(name: "ChdbClickBench", dependencies: ["Swift-chdb", "ClickhouseNative"], path: "Examples/ChdbClickBench"),
    .executableTarget(name: "ChdbClickBenchNative", dependencies: ["Swift-chdb", "ClickhouseNative"], path: "Examples/ChdbClickBenchNative"),
    .testTarget(name: "Swift-chdbTests", dependencies: ["Swift-chdb"]),
]

#if os(macOS)
// ChdbWebDemo requires Apple Network.framework — not available on Linux
let allProducts = products + [.executable(name: "chdb-web-demo", targets: ["ChdbWebDemo"])]
let allTargets = targets + [.executableTarget(name: "ChdbWebDemo", dependencies: ["Swift-chdb"], path: "Examples/ChdbWebDemo")]
#else
let allProducts = products
let allTargets = targets
#endif

let package = Package(
    name: "Swift-chdb",
    platforms: [.macOS(.v10_15)],
    products: allProducts,
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
    ],
    targets: allTargets,
    swiftLanguageModes: [.v6]
)

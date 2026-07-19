// swift-tools-version: 6.3

import PackageDescription

#if os(macOS) && arch(arm64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v4.0.2/Cchdb-macos-arm64.artifactbundle.zip",
    checksum: "5b194464939e9e64f745647ff71fda20968ef8e5e55811d2894a7275f0223404"
)
#elseif os(macOS) && arch(x86_64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v4.0.2/Cchdb-macos-x86_64.artifactbundle.zip",
    checksum: "e2e8eb78b387db7d49b1bacf711bcec3cc92455a7b5f263ec95bf1814e89f8ee"
)
#elseif os(Linux) && arch(x86_64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v4.0.2/Cchdb-linux-x86_64.artifactbundle.zip",
    checksum: "4a87887243665a210f2902c7c83190ddc2031470785a1c0c41ef9bb39d32147e"
)
#elseif os(Linux) && arch(arm64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v4.0.2/Cchdb-linux-aarch64.artifactbundle.zip",
    checksum: "8634456f78ae3584facc1d94ae3aac06499b9c87f5f894c9d52205ab12916ae3"
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

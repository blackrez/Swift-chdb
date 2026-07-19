// swift-tools-version: 6.3

import PackageDescription

#if os(macOS) && arch(arm64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-macos-arm64.artifactbundle.zip",
    checksum: "efaa34ac38aceb6733b7b7b818538ddc6fa144105a0bc4f0e94bae2c66ca6eac"
)
#elseif os(macOS) && arch(x86_64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-macos-x86_64.artifactbundle.zip",
    checksum: "eb1ddf544d864587d809d3a3bf5fac0454375af4da0111f27d6b6ff5017d2800"
)
#elseif os(Linux) && arch(x86_64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-linux-x86_64.artifactbundle.zip",
    checksum: "3854e623bdc0dd6bba55d8a90c5fcd0f58f7d35b6cefe1026b3553bd02debcd0"
)
#elseif os(Linux) && arch(arm64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-linux-aarch64.artifactbundle.zip",
    checksum: "69614bc99365b415e397bab14f0e7d281ecad9e16b3e542f6d190ee8ae7e2269"
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

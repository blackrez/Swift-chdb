// swift-tools-version: 6.3

import PackageDescription

#if os(macOS) && arch(arm64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-macos-arm64.artifactbundle.zip",
    checksum: "57083218ad91a85483e06e57fb2ffb99dae74af5bcbf34d72f6cc012827da639"
)
#elseif os(macOS) && arch(x86_64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-macos-x86_64.artifactbundle.zip",
    checksum: "eb339261e3ad92cc61e9046fa8b5bf81bfc6991b4ef9699839e640cfb8544ee2"
)
#elseif os(Linux) && arch(x86_64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-linux-x86_64.artifactbundle.zip",
    checksum: "f10ada06b52149226a7c83adadc504acd7874f22c02123691e6fa6c749a3bbbc"
)
#elseif os(Linux) && arch(arm64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-linux-aarch64.artifactbundle.zip",
    checksum: "2587bbd24039b6b0aef63dc5cb9c9535eb103f4b6928d2bee6a2f55a11c76ad9"
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

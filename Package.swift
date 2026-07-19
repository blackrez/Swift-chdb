// swift-tools-version: 6.3

import PackageDescription

#if os(macOS) && arch(arm64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-macos-arm64.artifactbundle.zip",
    checksum: "0c028f0e764ea1a436af4413f9db2eabf0f28f5cb6d33fdf755c34e33f54d762"
)
#elseif os(macOS) && arch(x86_64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-macos-x86_64.artifactbundle.zip",
    checksum: "87d53732d415f69e29a577ce1af810027c88a7f26d3ad44e12dcd77b000d6cb2"
)
#elseif os(Linux) && arch(x86_64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-linux-x86_64.artifactbundle.zip",
    checksum: "e556f789d64d463b920370498a4e848a703bfdfbf1a5425cf7fe0c43bd3939f0"
)
#elseif os(Linux) && arch(arm64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-linux-aarch64.artifactbundle.zip",
    checksum: "4c1e9c7f1a2823f10b806488913f74534e7283dc9a80443c0ed68483f9b92543"
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

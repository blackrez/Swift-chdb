// swift-tools-version: 6.3

import PackageDescription

#if os(macOS) && arch(arm64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-macos-arm64.artifactbundle.zip",
    checksum: "2e92a6630116af1c60e1231e6a70d38d1509b161b6672548bd71674a833005d5"
)
#elseif os(macOS) && arch(x86_64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-macos-x86_64.artifactbundle.zip",
    checksum: "76523a3141bf74b3e583280f116a0820ec823e7d53ef9600427e06249a75dd84"
)
#elseif os(Linux) && arch(x86_64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-linux-x86_64.artifactbundle.zip",
    checksum: "dc1321d023d3f2fd790a8e79246416f890f612bdbd2da0389f1dfc3d0d08e788"
)
#elseif os(Linux) && arch(arm64)
let chdbTarget: Target = .binaryTarget(
    name: "Cchdb",
    url: "https://github.com/blackrez/Swift-chdb/releases/download/v26.5.0/Cchdb-linux-aarch64.artifactbundle.zip",
    checksum: "556216fe4f6592bf1a5c47ad41b7730137afb4922fa406a8f95dd82a5a80bfd7"
)
#endif

let products: [Product] = [
    .library(name: "Swift-chdb", targets: ["Swift-chdb"]),
    .library(name: "ClickhouseNative", targets: ["ClickhouseNative"]),
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
    .executableTarget(name: "ChdbS3Demo", dependencies: ["Swift-chdb"], path: "Examples/ChdbS3Demo"),
    .testTarget(name: "Swift-chdbTests", dependencies: ["Swift-chdb"]),
]

let package = Package(
    name: "Swift-chdb",
    platforms: [.macOS(.v10_15)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
    ],
    targets: targets,
    swiftLanguageModes: [.v6]
)

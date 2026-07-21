// swift-tools-version: 6.3
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

#if os(macOS)
let chdbLinkerFlags = ["\(packageDir)/.local/lib/libchdb.dylib"]
#elseif os(Linux)
let chdbLinkerFlags = ["-lchdb"]
#else
let chdbLinkerFlags: [String] = []
#endif

let package = Package(
    name: "Swift-chdb",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "Swift-chdb", targets: ["Swift-chdb"]),
        .library(name: "ClickhouseNative", targets: ["ClickhouseNative"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
    ],
    targets: [
        .systemLibrary(name: "Clibchdb", path: "Sources/Clibchdb"),
        .target(name: "Cclickhouse"),
        .target(name: "Swift-chdb", dependencies: ["Clibchdb", "ClickhouseNative", .product(name: "NIOPosix", package: "swift-nio")],
            linkerSettings: [.unsafeFlags(chdbLinkerFlags)]),
        .target(name: "ClickhouseNative", dependencies: ["Cclickhouse"]),
        .executableTarget(name: "ChdbRepl", dependencies: ["Swift-chdb"], path: "Examples/ChdbRepl"),
        .executableTarget(name: "ChdbNativeDemo", dependencies: ["Swift-chdb", "ClickhouseNative"], path: "Examples/ChdbNativeDemo"),
        .executableTarget(name: "ChdbStreamDemo", dependencies: ["Swift-chdb", "ClickhouseNative"], path: "Examples/ChdbStreamDemo"),
        .executableTarget(name: "ChdbClickBench", dependencies: ["Swift-chdb", "ClickhouseNative"], path: "Examples/ChdbClickBench"),
        .executableTarget(name: "ChdbClickBenchNative", dependencies: ["Swift-chdb", "ClickhouseNative"], path: "Examples/ChdbClickBenchNative"),
        .executableTarget(name: "ChdbS3Demo", dependencies: ["Swift-chdb"], path: "Examples/ChdbS3Demo"),
        .testTarget(name: "Swift-chdbTests", dependencies: ["Swift-chdb"]),
        .testTarget(name: "ClickhouseNativeTests", dependencies: ["ClickhouseNative", "Cclickhouse"]),
    ],
    swiftLanguageModes: [.v6]
)

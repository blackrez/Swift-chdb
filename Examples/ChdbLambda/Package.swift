// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChdbLambda",
    dependencies: [
        .package(url: "https://github.com/awslabs/swift-aws-lambda-runtime.git", from: "2.0.0"),
        .package(url: "https://github.com/awslabs/swift-aws-lambda-events.git", from: "1.0.0"),
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "ChdbLambda",
            dependencies: [
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "Swift_chdb", package: "Swift-chdb"),
                .product(name: "ClickhouseNative", package: "Swift-chdb"),
            ]
        )
    ]
)

// swift-tools-version:5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "YouTubeKit",
    /*platforms: [
        .macOS(.v12), .iOS(.v15), .watchOS(.v8), .tvOS(.v15)
    ],*/
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "YouTubeKit",
            targets: ["YouTubeKit"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    .package(name: "YTDLPAPI", path: "/Users/xinnjie/Dev/watchbeats/protogen/swift2gen/ytdlp/v1"),
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "YouTubeKit",
      dependencies: [
        .product(name: "YTDLPAPI", package: "YTDLPAPI"),
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
      ],
            resources: [.process("Resources")]),
        .testTarget(
            name: "YouTubeKitTests",
            dependencies: ["YouTubeKit"]),
    ]
)

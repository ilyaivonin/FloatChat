// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FloatChat",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FloatChat", targets: ["FloatChat"])
    ],
    targets: [
        .executableTarget(
            name: "FloatChat",
            path: "Sources/FloatChat"
        )
    ]
)

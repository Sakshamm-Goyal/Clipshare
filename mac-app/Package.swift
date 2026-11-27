// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipboardMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ClipboardMac", targets: ["ClipboardMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClipboardMac",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources"
        )
    ]
)

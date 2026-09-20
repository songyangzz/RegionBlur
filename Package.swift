// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RegionBlur",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RegionBlurCore"),
        .executableTarget(name: "RegionBlur", dependencies: ["RegionBlurCore"]),
        .executableTarget(name: "RegionBlurTests", dependencies: ["RegionBlurCore"], path: "Tests/RegionBlurTests")
    ]
)

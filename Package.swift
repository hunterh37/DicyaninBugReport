// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DicyaninBugReport",
    platforms: [.iOS(.v17), .macOS(.v14), .visionOS(.v2)],
    products: [.library(name: "DicyaninBugReport", targets: ["DicyaninBugReport"])],
    targets: [
        .target(name: "DicyaninBugReport"),
        .testTarget(name: "DicyaninBugReportTests", dependencies: ["DicyaninBugReport"]),
    ],
    swiftLanguageModes: [.v5]
)

// swift-tools-version:5.9
// OloKit: everything in the Mac and iPhone apps that is not user interface. Foundation only,
// so it is unit tested with `swift test` on every push.
import PackageDescription

let package = Package(
    name: "OloKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "OloKit", targets: ["OloKit"])],
    targets: [
        .target(name: "OloKit"),
        .testTarget(name: "OloKitTests", dependencies: ["OloKit"]),
    ]
)

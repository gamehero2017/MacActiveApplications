// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacActiveApplications",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacActiveApplications"
        )
    ]
)

// swift-tools-version: 5.9
import PackageDescription

// libvlc is loaded at runtime with dlopen (see Vlc.swift), so nothing is linked at build time:
// `swift build` only needs the Command Line Tools. build-app.sh bundles libvlc into the .app.
let package = Package(
    name: "ICamLink",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ICamLink", path: "Sources/ICamLink"),
    ]
)

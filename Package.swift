// swift-tools-version: 6.0
import PackageDescription

// Standalone test harness for the same Core/ and Tests/ sources used by Xcode.
// The macOS application and embedded llama.cpp runtime still build with
// SuryaStudy.xcodeproj; this package does not build or distribute the app.
let package = Package(
    name: "SuryaDocumentCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SuryaStudy", path: "Core"),
        .testTarget(
            name: "SuryaStudyTests",
            dependencies: ["SuryaStudy"],
            path: "Tests"
        )
    ],
    swiftLanguageModes: [.v5]
)

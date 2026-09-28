// swift-tools-version: 5.9
//
// QuotientCore — the algorithm. Everything in this package is UI-free and
// platform-agnostic so it can be built and tested on macOS with a plain
// `swift test`, without booting an iOS simulator. The Quotient iOS app
// depends on this package as a local Swift package.
//
// Why a separate package rather than a folder inside the app target:
//   * The app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which
//     is right for UI code but wrong for a hot matching loop that a Monte
//     Carlo driver wants to run on background threads. Keeping the core in its
//     own module lets it be nonisolated by default.
//   * It gives interviewers a single URL that is "the algorithm", with its own
//     tests, and no SwiftUI in the way.
import PackageDescription

let package = Package(
    name: "QuotientCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "QuotientCore", targets: ["QuotientCore"]),
    ],
    targets: [
        .target(
            name: "QuotientCore",
            path: "Sources/QuotientCore",
            exclude: ["MarketData/ReferenceData/README.md"],
            resources: [.copy("MarketData/ReferenceData/market_snapshot.json")],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "QuotientCoreTests",
            dependencies: ["QuotientCore"],
            path: "Tests/QuotientCoreTests"
        ),
    ]
)

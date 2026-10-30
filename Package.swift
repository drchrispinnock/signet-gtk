// swift-tools-version:6.0
import PackageDescription

/// Upstream files that need macOS frameworks (JavaScriptCore's Objective-C API, AppKit, Core Image,
/// Sparkle). Sources/SignetGTK/Platform has a replacement for each one the rest of the module
/// needs; the others are left out until a view needs them.
let macOnly = [
    "Services/TaquitoBridge.swift",
    "Services/QRCode.swift",
    "Services/ImageLoader.swift",
    "Services/ArtworkCache.swift",
    "Services/Appearance.swift",
    "Services/UpdaterService.swift",
    "Services/tzel_blake2s.c",
    "Services/tzel_blake2s.h",
    "Resources/Assets.xcassets",
    "Resources/Credits.rtf",
].map { "upstream/Signet/\($0)" }

let macOnlyTests = [
    "ArtworkCacheTests.swift",
    "ArtworkPolicyTests.swift",
    "AuditRepairTests.swift",
    "AvatarTests.swift",
    "BuyWebViewTests.swift",
    "MtPelerinTests.swift",
    "NFTTests.swift",
    "QRCodeTests.swift",
    "TestHostIsolationTests.swift",
    "UpdaterTests.swift",
]

let package = Package(
    name: "signet-gtk",
    products: [.executable(name: "signet-gtk", targets: ["Signet"])],
    dependencies: [
        // CryptoKit's API on Linux and the BSDs.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "CTzel", path: "Sources/CTzel", cSettings: [.unsafeFlags(["-O3"])]),
        .systemLibrary(name: "CJavaScriptCore", path: "Sources/CJavaScriptCore", pkgConfig: "javascriptcoregtk-6.0",
                       providers: [.apt(["libjavascriptcoregtk-6.0-dev"])]),
        .systemLibrary(name: "CHidapi", path: "Sources/CHidapi", pkgConfig: "hidapi-hidraw",
                       providers: [.apt(["libhidapi-dev"])]),
        .systemLibrary(name: "CAdwaita", path: "Sources/CAdwaita", pkgConfig: "libadwaita-1",
                       providers: [.apt(["libadwaita-1-dev"])]),
        // Upstream's Models, Services and ViewModels compiled as they are, plus the GTK app and
        // the replacements for the Mac-only files: one module named Signet holding everything,
        // as on the Mac, so upstream's `@testable import Signet` tests run here unchanged.
        .executableTarget(
            name: "Signet",
            dependencies: ["CTzel", "CJavaScriptCore", "CHidapi", "CAdwaita", .product(name: "Crypto", package: "swift-crypto")],
            path: ".",
            exclude: macOnly,
            sources: ["upstream/Signet/Models", "upstream/Signet/Services", "upstream/Signet/ViewModels", "Sources/SignetGTK"],
            resources: [
                .copy("upstream/Signet/Resources/taquito-bridge.js"),
                .copy("upstream/Signet/Resources/tzel-shadownet-producer.json"),
            ],
            swiftSettings: [
                // Upstream reaches the C hashing through Xcode's bridging header; do the same.
                .unsafeFlags(["-import-objc-header", "\(Context.packageDirectory)/Sources/CTzel/include/tzel_blake2s.h"]),
            ]
        ),
        // Upstream's tests, unchanged, less those that exercise Mac-only code (views, AppKit
        // images, WebKit). Each left out here waits on the GTK version of what it tests.
        .testTarget(name: "SignetTests", dependencies: ["Signet", .product(name: "Crypto", package: "swift-crypto")], path: "upstream/SignetTests", exclude: macOnlyTests),
    ]
)

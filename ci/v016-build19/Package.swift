// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "SwiftVLC",
  platforms: [.iOS(.v16), .macOS(.v15), .tvOS(.v18), .visionOS(.v2), .macCatalyst(.v18)],
  products: [
    .library(name: "SwiftVLC", targets: ["SwiftVLC"])
  ],
  dependencies: [
    // 7z/LZMA engine used only by ArchiveExtractor for .7z and split .7z volumes.
    // Use the CI-pinned local checkout so upstream unsafe compiler flags can be
    // removed without changing any BTMobile source or the V0.1.5 BT core.
    .package(path: "../PLzmaSDK"),
    // Build-time plugin only; not linked into consumers.
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.6"),
    // Test-only. Produces diff-style failure messages for struct/enum
    // comparisons, replacing Swift Testing's "true vs false" default.
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.3"),
    .package(url: "https://github.com/pointfreeco/swift-perception", from: "2.0.10")
  ],
  targets: [
    .binaryTarget(
      name: "libvlc",
      url: "https://github.com/XITRIX/SwiftVLC/releases/download/v1.0.1/libvlc.xcframework.zip",
      checksum: "762ddbd56f74231148fdc4a54ebe0597f4a9ce6bae0ce0d4360f790b8c574275"
    ),
    .target(
      name: "CLibVLC",
      dependencies: ["libvlc"],
      publicHeadersPath: "include",
      linkerSettings: [
        // System frameworks required by libVLC
        .linkedFramework("AudioToolbox"),
        .linkedFramework("AudioUnit", .when(platforms: [.macOS])),
        .linkedFramework("AVFoundation"),
        .linkedFramework("AVKit"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("CoreFoundation"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("CoreImage"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("CoreServices"),
        .linkedFramework("CoreText"),
        .linkedFramework("CoreVideo"),
        .linkedFramework("Foundation"),
        .linkedFramework("IOKit", .when(platforms: [.macOS])),
        .linkedFramework("IOSurface"),
        .linkedFramework("OpenGL", .when(platforms: [.macOS])),
        .linkedFramework("OpenGLES", .when(platforms: [.iOS, .tvOS, .visionOS])),
        .linkedFramework("QuartzCore"),
        .linkedFramework("Security"),
        .linkedFramework("SystemConfiguration"),
        .linkedFramework("VideoToolbox"),

        // System libraries required by libVLC and its contribs
        .linkedLibrary("bz2"),
        .linkedLibrary("c++"),
        .linkedLibrary("iconv"),
        .linkedLibrary("resolv"),
        .linkedLibrary("sqlite3"),
        .linkedLibrary("xml2"),
        .linkedLibrary("z")
      ]
    ),
    .target(
      name: "SwiftVLC",
      dependencies: [
        "CLibVLC",
        .product(name: "PLzmaSDK", package: "PLzmaSDK"),
        .product(name: "Perception", package: "swift-perception")
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        // Upcoming features that become default in Swift 7 — opt-in early
        // to keep the codebase forward-compatible and catch issues now.
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"), // SE-0461
        .enableUpcomingFeature("MemberImportVisibility"), // SE-0444
        .enableUpcomingFeature("InferIsolatedConformances"), // SE-0449
        .enableUpcomingFeature("ImmutableWeakCaptures"), // SE-0481
        // Experimental: @_lifetime(borrow …) for ~Escapable overlays
        // (Marquee / Logo / VideoAdjustments).
        .enableExperimentalFeature("Lifetimes")
      ]
    ),
    .testTarget(
      name: "SwiftVLCTests",
      // CLibVLC is available transitively through SwiftVLC. Re-linking it
      // here can load duplicate Objective-C runtime classes from libVLC's
      // static dependencies.
      dependencies: [
        "SwiftVLC",
        .product(name: "CustomDump", package: "swift-custom-dump")
      ],
      resources: [.copy("Fixtures")],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("MemberImportVisibility")
      ]
    )
  ]
)

// swift-tools-version: 6.0
import Foundation
import PackageDescription

// FreeRDP and OpenSSL are built from pinned sources by scripts/build-deps.sh into Vendor/prefix.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendor = "\(root)/Vendor/prefix"

let package = Package(
    name: "AfarDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AfarDesktop", targets: ["AfarDesktop"]),
    ],
    targets: [
        // C glue over FreeRDP (the RDP engine) and OpenSSL and zlib (transport for VNC).
        .target(
            name: "AfarEngine",
            cSettings: [
                .unsafeFlags(["-isystem", "\(vendor)/include/freerdp3", "-isystem", "\(vendor)/include/winpr3",
                              "-isystem", "\(vendor)/include"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(vendor)/lib"]),
                .linkedLibrary("AfarFreeRDP"),
                .linkedLibrary("z"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Security"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("IOKit"),
            ]
        ),
        // Sessions, saved connections and credentials; no UI.
        .target(
            name: "AfarKit",
            dependencies: ["AfarEngine"]
        ),
        .executableTarget(
            name: "AfarDesktop",
            dependencies: ["AfarKit"]
        ),
        // Headless connection check for development: connects, reports, saves one frame.
        .executableTarget(
            name: "afar-probe",
            dependencies: ["AfarKit"]
        ),
        .testTarget(
            name: "AfarKitTests",
            dependencies: ["AfarKit"]
        ),
    ]
)

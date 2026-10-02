// swift-tools-version:5.9
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let lib = "\(root)/build-lib"
let brew = "/opt/homebrew/opt"

let staticLibraries = [
    "\(lib)/lib/libchiaki.a",
    "\(lib)/third-party/libjerasure.a",
    "\(lib)/third-party/libgf_complete.a",
    "\(lib)/third-party/nanopb/libprotobuf-nanopb.a",
    "\(lib)/third-party/curl/lib/libcurl.a",
    "\(brew)/openssl@3/lib/libssl.a",
    "\(brew)/openssl@3/lib/libcrypto.a",
    "\(brew)/opus/lib/libopus.a",
    "\(brew)/json-c/lib/libjson-c.a",
    "\(brew)/miniupnpc/lib/libminiupnpc.a",
    "\(brew)/libevent/lib/libevent.a",
    "\(brew)/libnghttp2/lib/libnghttp2.a",
    "\(brew)/libidn2/lib/libidn2.a",
    "\(brew)/libunistring/lib/libunistring.a",
]

let package = Package(
    name: "Teriyaki",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CChiaki",
            path: "Sources/CChiaki",
            cSettings: [.unsafeFlags(["-I\(root)/lib/include", "-I\(lib)/lib/include"])]
        ),
        .executableTarget(
            name: "Teriyaki",
            dependencies: ["CChiaki"],
            path: "Sources/Teriyaki",
            linkerSettings: [
                .unsafeFlags(staticLibraries),
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
                .linkedFramework("CoreServices"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)

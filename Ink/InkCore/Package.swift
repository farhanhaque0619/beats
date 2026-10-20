// swift-tools-version:6.0
// InkCore: everything in Ink that isn't UI. Foundation-only, so it builds and tests on Linux too.
import PackageDescription

let package = Package(
    name: "InkCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "InkCore", targets: ["InkCore"]),
    ],
    targets: [
        // Shared value types and the protocols the layers talk through.
        .target(name: "InkModel"),
        // MIME parsing and building, encodings, charsets, addresses, HTML-to-text, reply quoting.
        .target(name: "InkMIME", dependencies: ["InkModel"]),
        // IMAP4rev1/rev2 client: command encoder, response parser, connection, client.
        .target(name: "InkIMAP", dependencies: ["InkModel"]),
        // SMTP submission client.
        .target(name: "InkSMTP", dependencies: ["InkModel"]),
        // Provider presets, server autodiscovery and OAuth 2.0 (PKCE, token exchange).
        .target(name: "InkProviders", dependencies: ["InkModel"]),
        // Mail services (IMAP-backed and demo), cache, threading, and the observable MailStore.
        .target(name: "InkSync", dependencies: ["InkModel", "InkMIME", "InkIMAP", "InkSMTP", "InkProviders"]),
        // Umbrella module the app imports.
        .target(name: "InkCore", dependencies: ["InkModel", "InkMIME", "InkIMAP", "InkSMTP", "InkProviders", "InkSync"]),

        .testTarget(name: "InkMIMETests", dependencies: ["InkMIME"]),
        .testTarget(name: "InkIMAPTests", dependencies: ["InkIMAP"]),
        .testTarget(name: "InkSMTPTests", dependencies: ["InkSMTP"]),
        .testTarget(name: "InkProvidersTests", dependencies: ["InkProviders"]),
        .testTarget(name: "InkSyncTests", dependencies: ["InkSync"]),
    ],
    // Swift 5 mode: concurrency diagnostics stay warnings while the app is young.
    swiftLanguageModes: [.v5]
)

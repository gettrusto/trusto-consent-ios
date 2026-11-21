// swift-tools-version:5.9
import PackageDescription

// SDK de consentimento da Trusto para iOS (ADR 0135, M2). Sem dependência além da plataforma.
let package = Package(
    name: "TrustoConsent",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "TrustoConsent", targets: ["TrustoConsent"]),
    ],
    targets: [
        .target(name: "TrustoConsent", path: "Sources/TrustoConsent"),
        .testTarget(name: "TrustoConsentTests", dependencies: ["TrustoConsent"], path: "Tests/TrustoConsentTests"),
    ]
)

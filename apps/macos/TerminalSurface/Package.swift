// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalDBTerminal",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TerminalDBTerminal", type: .static, targets: ["TerminalDBTerminal"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.21.1"),
    ],
    targets: [
        .target(name: "TerminalDBTerminal", dependencies: [
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "X509", package: "swift-certificates"),
        ]),
        // Run without XCTest so Command Line Tools-only installs and CI match.
        .executableTarget(name: "TerminalSurfaceTests", dependencies: ["TerminalDBTerminal", .product(name: "SwiftTerm", package: "SwiftTerm")], path: "Tests/TerminalSurfaceTests")
    ],
    swiftLanguageModes: [.v5]
)

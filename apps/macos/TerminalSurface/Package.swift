// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalDBTerminal",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TerminalDBTerminal", type: .static, targets: ["TerminalDBTerminal"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0")],
    targets: [
        .target(name: "TerminalDBTerminal", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        // Run without XCTest so Command Line Tools-only installs and CI match.
        .executableTarget(name: "TerminalSurfaceTests", dependencies: ["TerminalDBTerminal", .product(name: "SwiftTerm", package: "SwiftTerm")], path: "Tests/TerminalSurfaceTests")
    ],
    swiftLanguageModes: [.v5]
)

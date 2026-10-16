// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MLXCreate",
    platforms: [.macOS("26.2")],
    products: [
        .library(name: "MCEngine", targets: ["MCEngine"]),
        .library(name: "MCCatalog", targets: ["MCCatalog"]),
        .executable(name: "mc-catalog", targets: ["MCCatalogTool"]),
        .library(name: "MCLibrary", targets: ["MCLibrary"]),
        .library(name: "MCGeneration", targets: ["MCGeneration"]),
        .library(name: "MCApp", targets: ["MCApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "MCEngine"),
        .target(name: "MCCatalog", resources: [.process("Resources")]),
        .target(name: "MCLibrary", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "MCGeneration", dependencies: ["MCEngine", "MCCatalog", "MCLibrary"]),
        .target(name: "MCApp", dependencies: ["MCGeneration", "MCEngine", "MCCatalog", "MCLibrary"]),
        .testTarget(name: "MCEngineTests", dependencies: ["MCEngine"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MCCatalogTests", dependencies: ["MCCatalog"], resources: [.copy("Fixtures")]),
        .executableTarget(name: "MCCatalogTool", dependencies: ["MCCatalog"]),
        .testTarget(name: "MCCatalogToolTests", dependencies: ["MCCatalogTool", "MCCatalog"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MCLibraryTests", dependencies: ["MCLibrary"]),
        .testTarget(name: "MCGenerationTests", dependencies: ["MCGeneration"]),
        .testTarget(name: "MCAppTests", dependencies: ["MCApp"]),
    ],
    swiftLanguageModes: [.v6]
)

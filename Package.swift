// swift-tools-version:5.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AlgorigoBleLibrary",
    platforms: [
        .macOS(.v10_13), .iOS(.v13)
    ],
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "AlgorigoBleLibrary",
            targets: ["AlgorigoBleLibrary"]
        ),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url: "https://github.com/ReactiveX/RxSwift.git", from: "6.5.0"),
        .package(url: "https://github.com/NordicSemiconductor/IOS-nRF-Wi-Fi-Provisioner.git", .upToNextMajor(from: "2.1.1")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "AlgorigoBleLibrary",
            dependencies: [
                "RxSwift",
                .product(name: "RxRelay", package: "RxSwift"),
                .product(name: "NordicWiFiProvisioner-BLE", package: "IOS-nRF-Wi-Fi-Provisioner"),
            ],
            path: "AlgorigoBleLibrary/AlgorigoBleLibrary"
        ),
        .testTarget(
            name: "AlgorigoBleLibraryTests",
            dependencies: ["AlgorigoBleLibrary"],
            path: "AlgorigoBleLibrary/AlgorigoBleLibraryTests"
        ),
    ]
)

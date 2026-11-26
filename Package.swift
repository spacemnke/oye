// swift-tools-version:5.9
import PackageDescription

// OyeCore holds the rules (people, messages, invites) with no AppKit, so it builds and tests anywhere.
var products: [Product] = [.library(name: "OyeCore", targets: ["OyeCore"])]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "OyeCore"),
    .testTarget(name: "OyeCoreTests", dependencies: ["OyeCore"])
]

#if os(macOS)
// The Mac app: faces in the menu bar, a thread under each. Supabase holds accounts and messages
// (the same project as Talkie; Oye's tables all start with oye_).
products.append(.executable(name: "Oye", targets: ["Oye"]))
dependencies += [
    .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.55.3"),
    // Voice for hold to talk, the same version Talkie uses.
    .package(url: "https://github.com/livekit/client-sdk-swift.git", exact: "2.17.0")
]
targets.append(
    .executableTarget(
        name: "Oye",
        dependencies: [
            "OyeCore",
            .product(name: "Supabase", package: "supabase-swift"),
            .product(name: "LiveKit", package: "client-sdk-swift")
        ],
        // Inter (the typeface in the designs) and the placeholder faces for demo mode.
        resources: [.copy("Resources/Fonts"), .copy("Resources/Demo")]
    )
)
#endif

let package = Package(
    name: "Oye",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)

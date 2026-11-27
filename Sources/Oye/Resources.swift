import Foundation

/// Finds the fonts and demo faces that ship with Oye. In the packaged app they sit in
/// Oye.app/Contents/Resources; when run straight from a build they sit beside the binary.
/// (SwiftPM's own Bundle.module only looks beside the app and at the build folder on the
/// machine that built it, so it can't be relied on once the app is on someone else's Mac.)
enum Resources {
    private static let bundle: Bundle? = {
        let name = "Oye_Oye.bundle"
        let places = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent()
        ]
        for place in places.compactMap({ $0 }) {
            if let found = Bundle(url: place.appendingPathComponent(name)) { return found }
        }
        return nil
    }()

    /// A folder inside the resources ("Fonts", "Demo"), or nil if it isn't there.
    static func folder(_ name: String) -> URL? {
        guard let url = bundle?.url(forResource: name, withExtension: nil),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

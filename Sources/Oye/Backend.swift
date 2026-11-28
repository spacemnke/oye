import Foundation
import Supabase
import OyeCore

/// Where Oye's accounts and messages live: the same Supabase project as Talkie. The key is the
/// project's public (anon) key: it only identifies the project, and row-level security decides
/// what anyone signed in can see or change.
enum Backend {
    static let url = URL(string: "https://xakscsouugwlyefaieyl.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhha3Njc291dWd3bHllZmFpZXlsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE4Mjk2ODEsImV4cCI6MjEwNzQwNTY4MX0.TXm0gnDiNHm3On8pV5zSZ4Fjot7qq-_8uCNqVb9lnZQ"

    /// Where files go: Oye's file server on Cloudflare (cloudflare/worker.js), in front of an R2 bucket.
    static let files = URL(string: Invite.site)!

    static func client() -> SupabaseClient {
        SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(auth: .init(storage: DefaultsAuthStorage(), emitLocalSessionAsInitialSession: true))
        )
    }
}

/// Keeps the sign-in in Oye's preferences rather than the keychain: test builds are signed ad hoc,
/// so every new build would otherwise have to ask for keychain access.
struct DefaultsAuthStorage: AuthLocalStorage {
    private func key(_ key: String) -> String { "oye.auth." + key }
    func store(key: String, value: Data) throws { Prefs.store.set(value, forKey: self.key(key)) }
    func retrieve(key: String) throws -> Data? { Prefs.store.data(forKey: self.key(key)) }
    func remove(key: String) throws { Prefs.store.removeObject(forKey: self.key(key)) }
}

/// Where Oye keeps your name, sign-in and settings. OYE_PROFILE=name gives a second copy of Oye
/// its own set, so two people can run on one Mac (the live check does this).
enum Prefs {
    private static let profile: String? = {
        let name = ProcessInfo.processInfo.environment["OYE_PROFILE"] ?? ""
        return name.isEmpty ? nil : name
    }()

    static let store: UserDefaults = {
        if let profile, let own = UserDefaults(suiteName: "com.spacemnke.oye." + profile) { return own }
        return .standard
    }()

    /// A folder of Oye's own on this Mac, one per profile: "Sent" in Application Support for the
    /// recordings you've sent, "Received" in Caches for what you've opened.
    static func folder(_ name: String, in place: FileManager.SearchPathDirectory) -> URL {
        let base = FileManager.default.urls(for: place, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(profile.map { "Oye-" + $0 } ?? "Oye", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }
}

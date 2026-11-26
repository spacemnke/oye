import Foundation
import Supabase

/// Where Oye's accounts and messages live: the same Supabase project as Talkie. The key is the
/// project's public (anon) key: it only identifies the project, and row-level security decides
/// what anyone signed in can see or change.
enum Backend {
    static let url = URL(string: "https://xakscsouugwlyefaieyl.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhha3Njc291dWd3bHllZmFpZXlsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE4Mjk2ODEsImV4cCI6MjEwNzQwNTY4MX0.TXm0gnDiNHm3On8pV5zSZ4Fjot7qq-_8uCNqVb9lnZQ"

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
    func store(key: String, value: Data) throws { UserDefaults.standard.set(value, forKey: self.key(key)) }
    func retrieve(key: String) throws -> Data? { UserDefaults.standard.data(forKey: self.key(key)) }
    func remove(key: String) throws { UserDefaults.standard.removeObject(forKey: self.key(key)) }
}

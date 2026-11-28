import Foundation
import Supabase
import OyeCore

/// A file on its way up.
struct Transfer: Identifiable, Equatable {
    let id: UUID
    /// Who it's for. Nil for a link anyone can open.
    let to: UUID?
    let name: String
    var sent: Int
    let size: Int

    var fraction: Double { size > 0 ? min(1, Double(sent) / Double(size)) : 0 }
}

enum FileProblem: Error {
    case empty, tooBig, tooMuchWaiting, expired, notAllowed
    case refused(Int)
}

/// Talking to Oye's file server (cloudflare/worker.js): files go up in parts and come down whole.
extension Store {
    private struct Started: Decodable {
        let key: String
        let upload: String
        let part: Int
        let link: String?
    }

    private struct PartDone: Codable {
        let partNumber: Int
        let etag: String
    }

    private struct StartBody: Encodable {
        let to: String?
        let name: String
        let size: Int
        let type: String
        let `extension`: String
        let invite: String?
    }

    private struct FinishBody: Encodable {
        let key: String
        let upload: String
        let parts: [PartDone]
    }

    private struct Finished: Decodable {
        let key: String
        let size: Int
    }

    private static func serverURL(_ path: String, _ query: [(String, String)] = []) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        var text = Backend.files.absoluteString + "/" + path
        if !query.isEmpty {
            text += "?" + query.map { key, value in
                key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            }.joined(separator: "&")
        }
        return URL(string: text)!
    }

    /// A request that says who you are, so the server can check you're allowed.
    private func signed(_ url: URL, method: String) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let token = try await client.auth.session.accessToken
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }

    private static func problem(_ status: Int) -> FileProblem {
        switch status {
        case 403: return .notAllowed
        case 410: return .expired
        case 413: return .tooBig
        case 429: return .tooMuchWaiting
        default: return .refused(status)
        }
    }

    private static func answer<T: Decodable>(_ request: URLRequest, body: Data? = nil) async throws -> T {
        let result: (Data, URLResponse)
        if let body {
            result = try await URLSession.shared.upload(for: request, from: body)
        } else {
            result = try await URLSession.shared.data(for: request)
        }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw problem(status) }
        return try JSONDecoder().decode(T.self, from: result.0)
    }

    /// Sends a file up in parts, reading it a part at a time. `to` is the friend it's for; without
    /// one it becomes a link anyone can open. Returns where it is on the server, and that link.
    func push(_ file: URL, name: String, type: String, to: UUID?, invite: String? = nil) async throws -> (key: String, link: String?, size: Int) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0
        guard size > 0 else { throw FileProblem.empty }
        guard size <= Files.largest else { throw FileProblem.tooBig }

        let transfer = Transfer(id: UUID(), to: to, name: name, sent: 0, size: size)
        transfers.append(transfer)
        defer { transfers.removeAll { $0.id == transfer.id } }

        var start = try await signed(Self.serverURL("api/upload/start"), method: "POST")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let asking = StartBody(to: to?.uuidString.lowercased(), name: name, size: size, type: type,
                               extension: file.pathExtension, invite: invite)
        let started: Started = try await Self.answer(start, body: try JSONEncoder().encode(asking))

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var done: [PartDone] = []
        for (index, piece) in Files.parts(size: size, part: started.part).enumerated() {
            try handle.seek(toOffset: UInt64(piece.offset))
            guard let data = try handle.read(upToCount: piece.length), data.count == piece.length else {
                throw FileProblem.refused(0)
            }
            done.append(try await pushPart(data, number: index + 1, of: started))
            if let at = transfers.firstIndex(where: { $0.id == transfer.id }) {
                transfers[at].sent = piece.offset + piece.length
            }
        }

        var finish = URLRequest(url: Self.serverURL("api/upload/finish"))
        finish.httpMethod = "POST"
        finish.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let closing = FinishBody(key: started.key, upload: started.upload, parts: done)
        let finished: Finished = try await Self.answer(finish, body: try JSONEncoder().encode(closing))
        return (finished.key, started.link, finished.size)
    }

    /// One part, tried up to four times: a blip in the connection costs a retry, not the file.
    private func pushPart(_ data: Data, number: Int, of started: Started) async throws -> PartDone {
        var request = URLRequest(url: Self.serverURL("api/upload/part", [("key", started.key), ("upload", started.upload), ("n", String(number))]))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        var last: Error = FileProblem.refused(0)
        for attempt in 0..<4 {
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000) }
            do {
                let part: PartDone = try await Self.answer(request, body: data)
                return part
            } catch {
                last = error
            }
        }
        throw last
    }

    /// Brings a friend's file down to `target`. Only the two people it's between are let in.
    func pull(_ key: String, to target: URL) async throws {
        let request = try await signed(Self.serverURL("api/file", [("key", key)]), method: "GET")
        let (arrived, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: arrived)
            throw Self.problem(status)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: arrived, to: target)
    }
}

import Foundation

enum NocturneAPIError: LocalizedError {
    case notConfigured
    case unauthorized(String)
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Enter your Nocturne address and token first."
        case .unauthorized(let detail):
            return "Nocturne refused the token. Check that it has the step count, heart rate and treatments write permissions.\(detail.isEmpty ? "" : " (\(detail))")"
        case .http(let code, let detail):
            return "Nocturne returned HTTP \(code).\(detail.isEmpty ? "" : " \(detail)")"
        case .badResponse:
            return "Nocturne sent a response the app couldn't read."
        }
    }
}

/// Writes health records to a Nocturne site with a `noc_` API token.
struct NocturneAPI {
    let baseURL: URL
    let token: String

    /// Nocturne accepts at most 1000 records per request.
    static let chunkSize = 500

    static func configured() throws -> NocturneAPI {
        guard let url = Prefs.baseURL, let token = Keychain.read(), !token.isEmpty else {
            throw NocturneAPIError.notConfigured
        }
        return NocturneAPI(baseURL: url, token: token)
    }

    /// Checks the address and token with a cheap read.
    func test() async throws {
        _ = try await send(method: "GET", path: "api/v4/StepCount",
                           query: [URLQueryItem(name: "count", value: "1")], body: nil)
    }

    /// POSTs records in chunks. Returns how many were sent.
    @discardableResult
    func post(_ path: String, _ records: [[String: Any]]) async throws -> Int {
        var sent = 0
        var start = 0
        while start < records.count {
            let chunk = Array(records[start..<min(start + Self.chunkSize, records.count)])
            let body = try JSONSerialization.data(withJSONObject: chunk)
            _ = try await send(method: "POST", path: path, query: [], body: body)
            sent += chunk.count
            start += Self.chunkSize
        }
        return sent
    }

    private func send(method: String, path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false) else {
            throw NocturneAPIError.badResponse
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw NocturneAPIError.badResponse }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw NocturneAPIError.badResponse }
        let detail = Self.snippet(data)
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw NocturneAPIError.unauthorized(detail)
        default: throw NocturneAPIError.http(http.statusCode, detail)
        }
    }

    private static func snippet(_ data: Data) -> String {
        guard let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return "" }
        return String(s.prefix(200))
    }

    /// Normalise what the user typed into a base URL like https://name.nocturne.run
    static func normalizedURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s), url.scheme?.lowercased() == "https", url.host != nil else {
            return nil
        }
        return url
    }
}

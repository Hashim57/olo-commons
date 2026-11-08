import Foundation

/// helius-olo.io speaks tRPC with the superjson transformer: inputs travel as
/// {"json": input}, results come back as {"result":{"data":{"json": value}}}.
/// This builds requests and reads responses in exactly that shape.
public enum TRPC {
    public struct RemoteError: Error, Equatable, LocalizedError {
        public var message: String
        public var code: String?
        public var httpStatus: Int
        public var errorDescription: String? { message }
        public var isUnauthorized: Bool { code == "UNAUTHORIZED" || httpStatus == 401 }
        /// The server does not have this procedure (an older deployment): the app carries on without it.
        public var isNotFound: Bool { code == "NOT_FOUND" || httpStatus == 404 }
    }

    struct Envelope<T: Encodable>: Encodable { let json: T }
    struct Result<T: Decodable>: Decodable {
        struct DataBox: Decodable { let json: T }
        struct Body: Decodable { let data: DataBox }
        let result: Body
    }

    /// A query (GET) for a procedure that takes no input.
    public static func queryRequest(base: URL, path: String, token: String?) throws -> URLRequest {
        try queryRequest(base: base, path: path, input: Optional<NoInput>.none, token: token)
    }

    /// A query (GET). `input` nil means the procedure takes none.
    public static func queryRequest<I: Encodable>(base: URL, path: String, input: I?, token: String?) throws -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent("api/trpc/\(path)"), resolvingAgainstBaseURL: false)!
        if let input {
            let data = try JSONEncoder().encode(Envelope(json: input))
            comps.queryItems = [URLQueryItem(name: "input", value: String(decoding: data, as: UTF8.self))]
        }
        // URLComponents leaves "+" and some JSON punctuation alone; encode them so the server reads the JSON back exactly.
        if let q = comps.percentEncodedQuery {
            comps.percentEncodedQuery = q.replacingOccurrences(of: "+", with: "%2B")
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        authorise(&req, token)
        return req
    }

    /// A mutation (POST) for a procedure that takes no input.
    public static func mutationRequest(base: URL, path: String, token: String?) throws -> URLRequest {
        try mutationRequest(base: base, path: path, input: Optional<NoInput>.none, token: token)
    }

    /// A mutation (POST).
    public static func mutationRequest<I: Encodable>(base: URL, path: String, input: I?, token: String?) throws -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent("api/trpc/\(path)"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let input {
            req.httpBody = try JSONEncoder().encode(Envelope(json: input))
        } else {
            req.httpBody = Data("{}".utf8)
        }
        authorise(&req, token)
        return req
    }

    static func authorise(_ req: inout URLRequest, _ token: String?) {
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    /// Reads a tRPC response body: the value on success, a RemoteError otherwise.
    public static func decode<T: Decodable>(_ type: T.Type, data: Data, status: Int) throws -> T {
        if (200..<300).contains(status), let ok = try? JSONDecoder().decode(Result<T>.self, from: data) {
            return ok.result.data.json
        }
        let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        let err = value?["error"]?["json"] ?? value?["error"]
        let message = err?["message"]?.stringValue ?? "helius-olo.io answered \(status)."
        let code = err?["data"]?["code"]?.stringValue
        throw RemoteError(message: message, code: code, httpStatus: status)
    }
}

/// An empty input for procedures that take an optional object.
public struct NoInput: Codable, Sendable { public init() {} }

import Foundation

struct ServerConfig: Equatable {
    var url: String
    var user: String
    var password: String

    var baseURL: URL? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    var isComplete: Bool { baseURL != nil }
}

enum APIError: LocalizedError {
    case badURL
    case unauthorized          // 代理层的基本认证没通过
    case forbidden(String)     // DSH 拒绝发放登录令牌（例如从公网直连）
    case http(Int)
    case server(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "服务器地址无效"
        case .unauthorized: return "用户名或密码不正确"
        case .forbidden(let text): return text.isEmpty ? "服务器拒绝了这次访问" : text
        case .http(let code): return "服务器返回 \(code)"
        case .server(let message): return message
        case .transport(let message): return message
        }
    }
}

/// 与 DS Bot 通信：先带基本认证访问首页换取 DSH 会话 Cookie，再调用 `POST /api/bot`。
/// 每个请求都主动带上 Authorization，所以不会像浏览器的 WebSocket / manifest 那样反复触发认证弹窗。
final class APIClient: NSObject, URLSessionTaskDelegate {
    private(set) var config: ServerConfig
    private let lock = NSLock()
    private var bootstrapTask: Task<Void, Error>?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(config: ServerConfig) {
        self.config = config
        super.init()
    }

    func update(_ config: ServerConfig) {
        lock.lock(); defer { lock.unlock() }
        self.config = config
        bootstrapTask = nil
        if let url = config.baseURL, let cookies = session.configuration.httpCookieStorage?.cookies(for: url) {
            for cookie in cookies { session.configuration.httpCookieStorage?.deleteCookie(cookie) }
        }
    }

    private var authorization: String? {
        guard !config.user.isEmpty else { return nil }
        let raw = Data("\(config.user):\(config.password)".utf8).base64EncodedString()
        return "Basic \(raw)"
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let base = config.baseURL, let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return request
    }

    // 重定向到同一主机时保留 Authorization（URLSession 默认可能丢弃）。
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if next.url?.host == config.baseURL?.host, let authorization {
            next.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }

    /// 访问首页：无 Cookie 时服务器 302 → /?token=… → 303 并下发 Cookie；最终 200 即握手成功。
    func bootstrap() async throws {
        lock.lock()
        if let existing = bootstrapTask { lock.unlock(); return try await existing.value }
        let task = Task { [self] in
            defer { lock.lock(); bootstrapTask = nil; lock.unlock() }
            let (data, response) = try await send(try request("/"))
            switch response.statusCode {
            case 200: return
            case 401: throw APIError.unauthorized
            case 403: throw APIError.forbidden(String(data: data, encoding: .utf8) ?? "")
            default: throw APIError.http(response.statusCode)
            }
        }
        bootstrapTask = task
        lock.unlock()
        try await task.value
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.transport("响应无效") }
            return (data, http)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport((error as NSError).localizedDescription)
        }
    }

    /// 与网页端同一条事件通道：`/api/remote.mux` 上多路复用的 WebSocket。
    /// 带上基本认证头和（URLSession 自动附带的）会话 Cookie。
    func makeWebSocketTask() throws -> URLSessionWebSocketTask {
        var req = try request("/api/remote.mux")
        guard var parts = URLComponents(url: req.url!, resolvingAgainstBaseURL: false) else { throw APIError.badURL }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        req.url = parts.url
        return session.webSocketTask(with: req)
    }

    /// DSH 自己的 RPC（`POST api/<method>`，信封 `{type, rpcId, method, payload:{args}}`），例如 `$events/result`。
    @discardableResult
    func dshCall(_ method: String, args: [String: Any], retry: Bool = true) async throws -> JSONValue {
        let envelope: [String: Any] = [
            "type": "client-request", "rpcId": UUID().uuidString, "method": method, "payload": ["args": args],
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        let (data, response) = try await send(try request("/api/" + method, method: "POST", body: body))
        if response.statusCode == 401 || response.statusCode == 302 || response.statusCode == 303 {
            guard retry else { throw APIError.unauthorized }
            try await bootstrap()
            return try await dshCall(method, args: args, retry: false)
        }
        guard response.statusCode == 200 else { throw APIError.http(response.statusCode) }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let result = json["result"]
        if result["ok"].bool == false { throw APIError.server(result["error"]["message"].string ?? "请求失败") }
        return result["value"]
    }

    /// 调用 DS Bot 的 RPC 端点；会话过期（401）时自动重新握手并重试一次。
    @discardableResult
    func call(_ endpoint: String, _ payload: [String: Any] = [:], retry: Bool = true) async throws -> JSONValue {
        let body = try JSONSerialization.data(withJSONObject: ["endpoint": endpoint, "payload": payload])
        let (data, response) = try await send(try request("/api/bot", method: "POST", body: body))
        if response.statusCode == 401 || response.statusCode == 302 || response.statusCode == 303 {
            guard retry else { throw APIError.unauthorized }
            try await bootstrap()
            return try await call(endpoint, payload, retry: false)
        }
        guard response.statusCode == 200 else { throw APIError.http(response.statusCode) }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        if json["ok"].bool == false {
            throw APIError.server(json["error"]["message"].string ?? "请求失败")
        }
        return json["value"]
    }
}

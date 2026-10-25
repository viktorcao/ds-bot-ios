import Foundation

/// DSH 的审批请求不经过 DS Bot 的 `/api/bot`，而是走 `/api/remote.mux` 上的 `$events` 流：
/// 服务器推下来 `{"type":"waterfall","event":"approval/request","eventId":…}`，
/// 客户端用 `POST api/$events/result` 带上 `clientId` 和 `eventId` 回答（`allowed-once` / `rejected`）。
struct ApprovalEvent: Hashable {
    let eventId: String
    let agentId: String
    let tool: String
    let reason: String
}

@MainActor
final class EventsChannel {
    private(set) var clientId: String?
    var onApproval: ((ApprovalEvent) -> Void)?
    var onReady: ((String) -> Void)?

    private let client: APIClient
    private var runner: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    init(client: APIClient) { self.client = client }

    func start() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            var delay = 1.0
            while !Task.isCancelled {
                guard let self else { return }
                let survived = await self.runOnce()
                delay = survived ? 1.0 : min(delay * 2, 15)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stop() {
        runner?.cancel()
        runner = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        clientId = nil
    }

    /// 连接一次并读到断开；返回这次连接是否成功握手过（用来重置退避）。
    private func runOnce() async -> Bool {
        guard let task = try? client.makeWebSocketTask() else { return false }
        socket = task
        task.resume()
        let streamId = UUID().uuidString
        let open: [String: Any] = ["type": "open", "streamId": streamId, "endpoint": "$events", "payload": ["args": [String: Any]()]]
        guard let data = try? JSONSerialization.data(withJSONObject: open), let text = String(data: data, encoding: .utf8) else { return false }
        do { try await task.send(.string(text)) } catch { return false }

        var ready = false
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() } catch { break }
            guard case .string(let raw) = message,
                  let json = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)),
                  json["type"].string == "item", json["streamId"].string == streamId else { continue }
            let value = json["value"]
            switch value["type"].string {
            case "ready":
                if let id = value["clientId"].string { clientId = id; ready = true; onReady?(id) }
            case "waterfall":
                guard value["event"].string == "approval/request", let eventId = value["eventId"].string else { continue }
                let request = value["request"]
                onApproval?(ApprovalEvent(
                    eventId: eventId,
                    agentId: value["agentId"].string ?? "",
                    tool: request["toolName"].string ?? "",
                    reason: request["displayReason"]["zh"].string ?? request["reason"].string ?? ""
                ))
            default: break
            }
        }
        clientId = nil
        return ready
    }

    /// 回答一个审批；`allow` 对应 `allowed-once`，否则 `rejected`。
    func answer(_ event: ApprovalEvent, allow: Bool) async throws {
        guard let clientId else { throw APIError.server("事件通道尚未连接，请稍后再试") }
        try await client.dshCall("$events/result", args: [
            "clientId": clientId,
            "eventId": event.eventId,
            "outcome": ["kind": "result", "value": allow ? "allowed-once" : "rejected"],
        ])
    }
}

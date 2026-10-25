import Foundation

/// 把状态和每个 Bot 最近的聊天缓存到本机（Caches 目录），冷启动或断网时先显示缓存，再后台同步。
/// - 每个 Bot 只留最近 `perBotItems` 条；
/// - 总量超过上限时，按“最近用过”从旧到新淘汰整个 Bot 的缓存，当前在用的永远最后被淘汰；
/// - 上限由设置里的“缓存上限”决定，随时可以清除。
enum ChatCache {
    static let perBotItems = 150
    static let limitOptions = [20, 50, 100, 200]   // MB

    static var limitBytes: Int { (UserDefaults.standard.object(forKey: "dsbot.cacheLimitMB") as? Int ?? 50) * 1_000_000 }

    private static let queue = DispatchQueue(label: "dsbot.cache", qos: .utility)
    private static var dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("dsbot-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static func file(_ name: String) -> URL { dir.appendingPathComponent(name) }
    private static func chatFile(_ botId: String) -> URL {
        // botId 不信任：只留安全字符，避免路径穿越
        file("chat-" + botId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } + ".json")
    }

    static func saveState(_ value: JSONValue) {
        write(value, to: file("state.json"))
    }

    static func loadState() -> JSONValue? { read(file("state.json")) }

    /// `value` 是服务端 `chat` 的返回；只保留最新 `perBotItems` 条
    static func saveChat(_ botId: String, _ value: JSONValue) {
        let items = Array(value["items"].array.suffix(perBotItems))
        let trimmed = JSONValue.object(["items": .array(items), "cursor": .null, "sessionId": value["sessionId"]])
        write(trimmed, to: chatFile(botId), trimAfter: true)
    }

    static func loadChat(_ botId: String) -> JSONValue? { read(chatFile(botId)) }

    /// 选中某个 Bot 就算“最近用过”，让它排在淘汰队列的最后
    static func touch(_ botId: String) {
        let url = chatFile(botId)
        queue.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
    }

    static func clear() {
        queue.sync {
            for url in files() { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func totalBytes() -> Int {
        queue.sync { files().reduce(0) { $0 + size($1) } }
    }

    // MARK: 内部
    private static func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
    }

    private static func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    private static func write(_ value: JSONValue, to url: URL, trimAfter: Bool = false) {
        queue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
            if trimAfter { trim() }
        }
    }

    private static func read(_ url: URL) -> JSONValue? {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }
    }

    /// 超过上限：先淘汰最久没用过的 Bot 缓存；状态文件很小，不参与淘汰
    private static func trim() {
        let limit = limitBytes
        var chats = files().filter { $0.lastPathComponent.hasPrefix("chat-") }
        var total = files().reduce(0) { $0 + size($1) }
        guard total > limit else { return }
        chats.sort {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for url in chats where total > limit {
            total -= size(url)
            try? FileManager.default.removeItem(at: url)
        }
    }
}

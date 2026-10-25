import SwiftUI

struct Bot: Identifiable, Hashable {
    let id: String
    var name: String
    var role: String
    var color: String
    var shape: String
    var avatarImage: String?
    var model: String
    var effort: String
    var waiting: Bool
    var instructions: String
    var permission: String?
    var workDir: String?
    var createdAt: Date

    init(_ json: JSONValue) {
        id = json["id"].string ?? UUID().uuidString
        name = json["name"].string ?? "Bot"
        role = json["role"].string ?? ""
        let rawShape = json["avatar"]["shape"].string ?? ""
        avatarImage = json["avatar"]["image"].string
        shape = CharacterArt.table.characters[rawShape] != nil ? rawShape : CharacterArt.defaultShape(json["id"].string ?? "")
        let rawColor = json["color"].string ?? ""
        color = (CharacterArt.isHex(rawColor) || CharacterArt.table.inks[rawColor] != nil) ? rawColor : CharacterArt.defaultColor(json["id"].string ?? "")
        model = json["model"].string ?? ""
        effort = json["effort"].string ?? ""
        waiting = json["waiting"].bool ?? false
        instructions = json["instructions"].string ?? ""
        permission = json["permission"].string
        workDir = json["workDir"].string
        createdAt = Date(timeIntervalSince1970: (json["createdAt"].double ?? 0) / 1000)
    }
}

struct PermissionOption: Identifiable, Hashable {
    var id: String { value }
    let value: String
    let name: String
    var label: String {
        switch value {
        case "read-only": return "仅可查看"
        case "workspace-write": return "工作区内修改"
        case "danger-full-access": return "完全权限"
        default: return name
        }
    }
}

struct FolderOption: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let title: String
}

struct MemoryEntry: Identifiable, Hashable {
    var id: String { "\(scope)|\(topic)|\(text)" }
    let scope: String
    let topic: String
    let text: String
    let added: String
    init(_ json: JSONValue) {
        scope = json["scope"].string ?? "own"
        topic = json["topic"].string ?? ""
        text = json["text"].string ?? ""
        added = json["added"].string ?? ""
    }
}

struct MemoryView: Hashable {
    var entries: [MemoryEntry]
    var summary: String
    var summarizing: Bool
}

struct ScheduleTask: Identifiable, Hashable {
    let id: String
    let sessionId: String
    let title: String
    let prompt: String
    let when: String
    let owner: String
    init(_ json: JSONValue) {
        id = json["id"].string ?? UUID().uuidString
        sessionId = json["sessionId"].string ?? ""
        title = json["title"].string ?? "任务"
        prompt = json["prompt"].string ?? ""
        owner = json["name"].string ?? ""
        if let at = json["at"].string { when = "一次 · \(at)" }
        else if json["daily"]["time"].string != nil { when = "每天 \(json["daily"]["time"].string!.prefix(5))" }
        else if json["weekly"]["time"].string != nil {
            let names = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]
            let days = json["weekly"]["weekdays"].array.compactMap { $0.int }.map { names.indices.contains($0) ? names[$0] : "\($0)" }.joined(separator: " ")
            when = "每周 \(days) \(json["weekly"]["time"].string!.prefix(5))"
        }
        else if let seconds = json["every_seconds"].double { when = "每 \(Int(seconds / 60)) 分钟" }
        else { when = "" }
    }
}

struct UsageRow: Hashable {
    let hour: String      // "2026-10-19 17"
    let owner: Int
    let model: Int
    let kind: Int
    let input: Int
    let cacheRead: Int
    let cacheWrite: Int
    let output: Int
    let calls: Int
    var total: Int { input + cacheRead + cacheWrite + output }
}

struct UsageReport {
    struct Owner { let key: String; let name: String; let kind: String; let id: String? }
    var owners: [Owner] = []
    var models: [String] = []
    var rows: [UsageRow] = []
    var now = ""
    init() {}
    init(_ json: JSONValue) {
        owners = json["owners"].array.map { Owner(key: $0["key"].string ?? "", name: $0["name"].string ?? ($0["kind"].string == "other" ? "其他" : "?"), kind: $0["kind"].string ?? "", id: $0["id"].string) }
        models = json["models"].array.map { $0["name"].string ?? $0["model"].string ?? "" }
        now = json["now"].string ?? ""
        rows = json["rows"].array.compactMap { r in
            guard let hour = r[0].string else { return nil }
            return UsageRow(hour: hour, owner: r[1].int ?? 0, model: r[2].int ?? 0, kind: r[3].int ?? 0,
                            input: r[4].int ?? 0, cacheRead: r[5].int ?? 0, cacheWrite: r[6].int ?? 0, output: r[7].int ?? 0, calls: r[8].int ?? 0)
        }
    }
}

struct Room: Identifiable, Hashable {
    let id: String
    var name: String
    var preview: String
    var memberCount: Int

    init(_ json: JSONValue) {
        id = json["id"].string ?? UUID().uuidString
        name = json["name"].string ?? json["title"].string ?? "群聊"
        preview = json["preview"].string ?? ""
        memberCount = json["members"].array.count
    }
}

struct ModelOption: Identifiable, Hashable {
    var id: String { ref }
    let ref: String
    let name: String
    let provider: String
    let efforts: [String]

    init(_ json: JSONValue) {
        ref = json["ref"].string ?? ""
        name = json["name"].string ?? ref
        provider = json["providerName"].string ?? json["provider"].string ?? ""
        efforts = json["reasoning"]["efforts"].array.compactMap { $0["id"].string }
    }
}

enum ChatKind: String {
    case user, bot, other
}

struct ChatItem: Identifiable, Hashable {
    let id: String
    let kind: ChatKind
    let rawKind: String
    let text: String
    let time: Date
    /// 不含序号的内容指纹：同一条消息在窗口滑动前后保持不变，用来对齐已加载的历史
    let base: String

    /// `occurrence`：同一毫秒内完全相同的消息的第几条，保证 id 唯一
    init(_ json: JSONValue, occurrence: Int = 0) {
        let raw = json["kind"].string ?? "bot"
        rawKind = raw
        kind = ChatKind(rawValue: raw) ?? .other
        text = json["text"].string ?? ""
        let millis = json["time"].double ?? 0
        time = Date(timeIntervalSince1970: millis / 1000)
        base = "\(Int(millis))-\(raw)-\(text.hashValue)"
        id = "\(base)#\(occurrence)"
    }

    /// 解析一批服务端消息；id 只取决于内容，不依赖它在数组里的下标
    static func parse(_ values: [JSONValue]) -> [ChatItem] {
        var seen: [String: Int] = [:]
        return values.map { value in
            let probe = ChatItem(value)
            let n = seen[probe.base, default: 0]
            seen[probe.base] = n + 1
            return n == 0 ? probe : ChatItem(value, occurrence: n)
        }
    }

    init(localUser text: String) {
        rawKind = "user"
        kind = .user
        self.text = text
        time = Date()
        base = "local"
        id = "local-\(UUID().uuidString)"
    }
}

struct Approval: Identifiable, Hashable {
    let id: String
    let botId: String
    let roomId: String?
    let tool: String
    let reason: String
    let detail: String
    let title: String
    let answerable: Bool

    init(_ json: JSONValue) {
        id = json["id"].string ?? UUID().uuidString
        botId = json["botId"].string ?? ""
        roomId = json["roomId"].string
        tool = json["tool"].string ?? ""
        reason = json["reason"].string ?? ""
        detail = json["detail"]["code"].string ?? ""
        title = json["detail"]["text"].string ?? ""
        answerable = json["answerable"].bool ?? true
    }
}

struct QuestionOption: Hashable {
    let label: String
    let description: String
}

struct Question: Identifiable, Hashable {
    let id: String
    let sessionId: String
    let text: String
    let detail: String
    let options: [QuestionOption]
    let multiSelect: Bool

    init(sessionId: String, _ json: JSONValue) {
        id = json["id"].string ?? UUID().uuidString
        self.sessionId = sessionId
        text = json["question"].string ?? ""
        detail = json["detail"].string ?? ""
        options = json["options"].array.map { QuestionOption(label: $0["label"].string ?? "", description: $0["description"].string ?? "") }
        multiSelect = json["multiSelect"].bool ?? false
    }
}

/// Bot 正在做什么（来自 `work.bots`），用来显示“正在使用 xxx”。
struct Activity: Hashable {
    var tool: String
    var note: String = ""
    var since: Date? = nil
}

extension Bot {
    /// DS Bot 的预设颜色名 → SwiftUI 颜色
    var tint: Color { CharacterArt.isHex(color) ? Color(hex: color) : Palette.color(named: color) }
    /// 用户气泡用 Bot 的颜色；浅色底上要换黑字才看得清
    var onTint: Color { UIColor(tint).relativeLuminance > 0.6 ? .black : .white }
    var initial: String { String(name.trimmingCharacters(in: .whitespaces).first ?? "B").uppercased() }
}

extension UIColor {
    var relativeLuminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}

enum Palette {
    static func color(named name: String) -> Color {
        switch name {
        case "deepseek": return Color(red: 0.30, green: 0.42, blue: 1.0)
        case "blue": return .blue
        case "violet": return .purple
        case "orange": return .orange
        case "green": return .green
        case "magenta": return Color(red: 0.86, green: 0.2, blue: 0.7)
        case "cyan": return .cyan
        case "red": return .red
        case "yellow": return .yellow
        case "brown": return .brown
        case "gray": return .gray
        case "black": return Color(white: 0.12)
        case "aurora": return Color(red: 0.2, green: 0.8, blue: 0.65)
        case "charcoal": return Color(white: 0.28)
        case "graphite": return Color(white: 0.4)
        case "rose": return Color(red: 1.0, green: 0.45, blue: 0.6)
        case "sky": return Color(red: 0.4, green: 0.75, blue: 1.0)
        case "tangerine": return Color(red: 1.0, green: 0.55, blue: 0.1)
        case "cobalt": return Color(red: 0.0, green: 0.28, blue: 0.67)
        default: return .gray
        }
    }
}

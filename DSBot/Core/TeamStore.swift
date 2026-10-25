import SwiftUI
import Observation

enum Phase: Equatable {
    case needsLogin
    case connecting
    case ready
}

struct ChatBuffer: Equatable {
    var items: [ChatItem] = []
    var cursor: String?
    var sessionId: String = ""
    var loaded = false
    var loadingEarlier = false
}

@MainActor
@Observable
final class TeamStore {
    // MARK: 连接
    var phase: Phase = .needsLogin
    var config = TeamStore.savedConfig()
    var loginError: String?
    var offlineMessage: String?
    var banner: String?

    // MARK: 团队
    var bots: [Bot] = []
    var mainBotIds: [String] = []
    var rooms: [Room] = []
    var models: [ModelOption] = []
    var defaultModel = ""
    var approvals: [Approval] = []
    var questions: [String: Question] = [:]
    var working: [String: Activity] = [:]
    var selectedBotId: String?
    /// 是否正在看某个 Bot 的聊天页（false = 在 Bot 列表首页）。冷启动总是回到列表。
    var chatOpen = false
    /// 列表里每个 Bot 的最后一条消息（本机保存；服务端状态里没有这个字段）
    struct Preview: Codable, Equatable { var text: String; var time: Date }
    var previews: [String: Preview] = TeamStore.loadPreviews()
    var chats: [String: ChatBuffer] = [:]
    /// 刚被用户停止的 Bot（用于在聊天里显示“已停止”，几秒后消失）
    var stoppedAt: [String: Date] = [:]
    /// 在后台跑完、你还没看的 Bot（只存在本机，不同步）
    var unread: Set<String> = []
    /// 发送失败时放回输入框的文字（ChatView 接走后清空）
    struct RestoredDraft: Equatable { let botId: String; let text: String; let stamp = UUID() }
    var restoredDraft: RestoredDraft?
    @ObservationIgnored var appActive = true
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    var permissionOptions: [PermissionOption] = []
    var defaultPermission = "workspace-write"

    @ObservationIgnored private var client: APIClient
    @ObservationIgnored private var events: EventsChannel
    /// 事件通道推来的、尚未回答的审批（按 Bot 归类），用来给审批卡片补上 eventId。
    var eventApprovals: [String: [ApprovalEvent]] = [:]
    @ObservationIgnored private var revision = -1
    @ObservationIgnored private var modelsKey = ""
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var tick = 0
    /// 连续失败次数：离线时退避重试，别每 2.5 秒敲一次
    @ObservationIgnored private var failures = 0

    init() {
        let api = APIClient(config: TeamStore.savedConfig())
        client = api
        events = EventsChannel(client: api)
        events.onApproval = { [weak self] event in self?.receive(event) }
        if config.isComplete {
            restoreFromCache()
            Task { await connect() }
        }
    }

    // MARK: 配置持久化
    static func savedConfig() -> ServerConfig {
        let defaults = UserDefaults.standard
        return ServerConfig(
            url: defaults.string(forKey: "dsbot.url") ?? "",
            user: defaults.string(forKey: "dsbot.user") ?? "",
            password: Keychain.read("password") ?? ""
        )
    }

    private func persist(_ config: ServerConfig) {
        UserDefaults.standard.set(config.url, forKey: "dsbot.url")
        UserDefaults.standard.set(config.user, forKey: "dsbot.user")
        Keychain.write("password", value: config.password)
    }

    // MARK: 登录 / 退出
    func login(_ newConfig: ServerConfig) async {
        config = newConfig
        client.update(newConfig)
        loginError = nil
        phase = .connecting
        do {
            try await client.bootstrap()
            _ = try await client.call("state", ["locale": "zh"])
            persist(newConfig)
            await enter()
        } catch {
            loginError = error.localizedDescription
            phase = .needsLogin
        }
    }

    func logout() {
        stopPolling()
        Keychain.delete("password")
        UserDefaults.standard.removeObject(forKey: "dsbot.user")
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("dsbot.draft.") { UserDefaults.standard.removeObject(forKey: key) }
        config.password = ""
        client.update(config)
        bots = []; rooms = []; chats = [:]; approvals = []; questions = [:]; working = [:]; eventApprovals = [:]
        selectedBotId = nil
        chatOpen = false
        previews = [:]
        UserDefaults.standard.removeObject(forKey: "dsbot.previews")
        ChatCache.clear()
        UserDefaults.standard.removeObject(forKey: "dsbot.selectedBot")
        revision = -1
        phase = .needsLogin
    }

    private func connect() async {
        phase = .connecting
        do {
            try await client.bootstrap()
            await enter()
        } catch {
            // 只有凭据真的被拒绝才回登录页；断网、超时、服务器重启都留在应用里，后台不断重试
            switch error as? APIError {
            case .unauthorized, .forbidden, .badURL:
                loginError = error.localizedDescription
                phase = .needsLogin
            default:
                offlineMessage = error.localizedDescription
                phase = .ready
                startPolling()
            }
        }
    }

    /// 冷启动：先用本机缓存把界面撑起来（上次的 Bot 列表和聊天），再后台同步；断网也不是一片空白
    private func restoreFromCache() {
        guard let cached = ChatCache.loadState() else { return }
        applyFull(cached)
        revision = -1   // 缓存只用来先显示，第一次联网必须拉全量
        if let id = selectedBotId, let chat = ChatCache.loadChat(id) { applyChat(chat, botId: id) }
    }

    /// 离线屏上的“重试”
    func retryNow() { Task { await connect() } }

    private func enter() async {
        Task { await Notifier.requestIfNeeded() }
        phase = .ready
        revision = -1
        await refresh()
        if selectedBotId == nil {
            let saved = UserDefaults.standard.string(forKey: "dsbot.selectedBot")
            selectedBotId = bots.contains(where: { $0.id == saved }) ? saved : (mainBotIds.first ?? bots.first?.id)
        }
        if let id = selectedBotId { await loadChat(id) }
        startPolling()
        await prefetchPreviews()
    }

    // MARK: 轮询（与网页端一致：按 revision 增量拉取状态）
    func startPolling() {
        stopPolling()
        guard phase == .ready else { return }
        events.start()
        tick = 3   // 回到前台后的第一次轮询就重新拉当前聊天
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let busy = await self?.pollOnce() ?? false
                let failed = self?.failures ?? 0
                let delay = failed > 0 ? min(30_000, 2_500 * (1 << min(failed, 4))) : (busy ? 1200 : 2500)
                try? await Task.sleep(for: .milliseconds(delay))
            }
        }
    }

    /// 切到后台：向系统多要约 30 秒，期间继续轮询，有审批或完成就发本地通知
    func didEnterBackground() {
        appActive = false
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "dsbot.poll") { [weak self] in
            Task { @MainActor in self?.endBackground() }
        }
    }

    private func endBackground() {
        stopPolling()
        releaseBackgroundTask()
    }

    private func releaseBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func didBecomeActive() {
        appActive = true
        releaseBackgroundTask()
        Notifier.clearDelivered()
        startPolling()
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        events.stop()
    }

    private func receive(_ event: ApprovalEvent) {
        var list = eventApprovals[event.agentId] ?? []
        guard !list.contains(where: { $0.eventId == event.eventId }) else { return }
        list.append(event)
        eventApprovals[event.agentId] = list
    }

    /// DSH 单聊里的审批（`answerable == false`）要靠 `$events` 通道回答；群聊里的走 `approval-answer`。
    func eventFor(_ approval: Approval) -> ApprovalEvent? {
        eventApprovals[approval.botId]?.last { $0.tool == approval.tool }
    }

    func canAnswer(_ approval: Approval) -> Bool {
        approval.answerable || eventFor(approval) != nil
    }

    /// 返回当前是否有 Bot 在工作（用于加快轮询）。
    private func pollOnce() async -> Bool {
        let before = revision
        let wasBusy = selectedBotId.map { working[$0] != nil } ?? false
        if bots.isEmpty { try? await client.bootstrap() }   // 冷启动没连上过：先补一次登录握手
        await refresh()
        tick += 1
        let id = selectedBotId
        let busy = id.map { working[$0] != nil } ?? false
        // 刚从“工作中”变成空闲的这一轮必须立刻拉聊天：最终回复就在这时落库，等下一个周期会出现一段空白再突然弹出
        if let id, busy || wasBusy || revision != before || tick % 4 == 0 { await loadChat(id, quiet: true) }
        return !working.isEmpty
    }

    func refresh() async {
        do {
            let value = try await client.call("state", ["since": revision, "models": modelsKey, "locale": "zh"])
            if offlineMessage != nil { offlineMessage = nil }
            failures = 0
            applyLive(value)
            if value["unchanged"].bool != true { applyFull(value); ChatCache.saveState(value) }
        } catch {
            offlineMessage = error.localizedDescription
            failures += 1
        }
    }

    private func applyLive(_ value: JSONValue) {
        var next: [String: Activity] = [:]
        for (botId, entry) in value["work"]["bots"].object {
            next[botId] = Activity(
                tool: entry["tool"].string ?? entry.string ?? "",
                note: entry["note"].string ?? "",
                since: entry["since"].double.map { Date(timeIntervalSince1970: $0 / 1000) }
            )
        }
        for id in Set(working.keys).subtracting(next.keys) where stoppedAt[id] == nil {
            if appActive {
                if id == selectedBotId { UINotificationFeedbackGenerator().notificationOccurred(.success) } else { unread.insert(id) }
            } else {
                unread.insert(id)
                Notifier.post(id: "done-\(id)", title: "\(botName(id)) 完成了", body: "回到 DS Bot 查看结果")
            }
        }
        // 值没变就不赋值：Observation 不比较相等，赋值一次就会让所有读取它的页面重绘一次
        if working != next { working = next }
        let nextApprovals = value["work"]["approvals"].array.map(Approval.init)
        if approvals != nextApprovals {
            let known = Set(approvals.map(\.id))
            for item in nextApprovals where !known.contains(item.id) {
                if appActive { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
                else { Notifier.post(id: "approval-\(item.id)", title: "\(botName(item.botId)) 需要你批准", body: item.title.isEmpty ? item.tool : item.title) }
            }
            approvals = nextApprovals
            Notifier.setBadge(approvals.count + questions.count)
        }
        // 服务器已不再等待的审批（别的设备回答了、或被取消），事件也一并丢弃
        let pendingBots = Set(approvals.map(\.botId))
        for botId in eventApprovals.keys where !pendingBots.contains(botId) { eventApprovals[botId] = nil }
    }

    private func applyFull(_ value: JSONValue) {
        revision = value["revision"].int ?? revision
        modelsKey = value["modelsKey"].string ?? modelsKey
        bots = value["bots"].array.map(Bot.init)
        mainBotIds = value["mainBotIds"].array.compactMap { $0.string }
        rooms = value["rooms"].array.map(Room.init)
        models = value["models"].array.map(ModelOption.init)
        defaultModel = value["defaultModel"].string ?? defaultModel
        permissionOptions = value["permissions"]["options"].array.map { PermissionOption(value: $0["value"].string ?? "", name: $0["name"].string ?? "") }
        defaultPermission = value["permissions"]["defaultPreset"].string ?? defaultPermission
        var qs: [String: Question] = [:]
        for (sessionId, json) in value["questions"].object { qs[sessionId] = Question(sessionId: sessionId, json) }
        for (id, question) in qs where questions[id] == nil && !appActive {
            Notifier.post(id: "question-\(id)", title: "\(botName(id)) 想问你", body: question.text)
        }
        questions = qs
        if let id = selectedBotId, !bots.contains(where: { $0.id == id }) { selectedBotId = mainBotIds.first ?? bots.first?.id }
        else if selectedBotId == nil, !bots.isEmpty {
            // 冷启动时没连上、后来才连上：补选上次的 Bot 并拉聊天
            let saved = UserDefaults.standard.string(forKey: "dsbot.selectedBot")
            selectedBotId = bots.contains(where: { $0.id == saved }) ? saved : (mainBotIds.first ?? bots.first?.id)
            if let id = selectedBotId { Task { await loadChat(id) } }
        }
    }

    private func botName(_ id: String) -> String { bots.first { $0.id == id }?.name ?? "Bot" }

    // MARK: 聊天
    var selectedBot: Bot? { bots.first { $0.id == selectedBotId } }

    func closeChat() { chatOpen = false }

    private static func loadPreviews() -> [String: Preview] {
        guard let data = UserDefaults.standard.data(forKey: "dsbot.previews"),
              let value = try? JSONDecoder().decode([String: Preview].self, from: data) else { return [:] }
        return value
    }

    private func updatePreview(_ botId: String, items: [ChatItem]) {
        guard let last = items.last(where: { ($0.kind == .bot || $0.kind == .user) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        let text = last.text.replacingOccurrences(of: "\n", with: " ")
        let new = Preview(text: String(text.prefix(120)), time: last.time)
        guard previews[botId] != new else { return }
        previews[botId] = new
        if let data = try? JSONEncoder().encode(previews) { UserDefaults.standard.set(data, forKey: "dsbot.previews") }
    }

    /// 首次安装或新建的 Bot 还没有预览：安静地逐个拉一次聊天来补上（只补缺的，不重复拉）
    private func prefetchPreviews() async {
        for bot in bots where previews[bot.id] == nil && chats[bot.id] == nil {
            await loadChat(bot.id, quiet: true)
        }
    }

    func select(_ botId: String) {
        chatOpen = true
        selectedBotId = botId
        unread.remove(botId)
        ChatCache.touch(botId)
        UserDefaults.standard.set(botId, forKey: "dsbot.selectedBot")
        Task { await loadChat(botId) }
    }

    func loadChat(_ botId: String, quiet: Bool = false) async {
        do {
            let value = try await client.call("chat", ["botId": botId])
            // 内容没变就不重写缓存：别的 Bot 在跑时，状态版本号会不停变，当前页会被反复拉取
            if applyChat(value, botId: botId) { ChatCache.saveChat(botId, value) }
        } catch {
            if !quiet { banner = error.localizedDescription }
        }
    }

    @discardableResult
    private func applyChat(_ value: JSONValue, botId: String) -> Bool {
        var buffer = chats[botId] ?? ChatBuffer()
        let serverItems = ChatItem.parse(value["items"].array)
        // 保留尚未被服务端记录的本地乐观消息
        let pending = buffer.items.filter { local in
            local.id.hasPrefix("local-") && !serverItems.contains { $0.kind == .user && $0.text == local.text }
        }
        // 轮询只返回最新一窗；用户已经“加载更早”的部分要留着，不能被冲掉
        var older: [ChatItem] = []
        if let first = serverItems.first {
            let known = buffer.items.filter { !$0.id.hasPrefix("local-") }
            if let at = known.firstIndex(where: { $0.base == first.base }), at > 0 { older = Array(known[..<at]) }
        }
        buffer.items = older + serverItems + pending
        // 缓存先显示时没有游标：拿服务端的（重叠部分加载更早时会去重）
        if older.isEmpty || buffer.cursor == nil { buffer.cursor = value["cursor"].string }
        buffer.sessionId = value["sessionId"].string ?? botId
        buffer.loaded = true
        let changed = chats[botId] != buffer
        if changed { chats[botId] = buffer }
        updatePreview(botId, items: buffer.items)
        return changed
    }

    func loadEarlier(_ botId: String) async {
        guard var buffer = chats[botId], let cursor = buffer.cursor, !buffer.loadingEarlier else { return }
        buffer.loadingEarlier = true
        chats[botId] = buffer
        defer { chats[botId]?.loadingEarlier = false }
        do {
            let value = try await client.call("earlier", ["sessionId": buffer.sessionId, "cursor": cursor])
            let have = Set((chats[botId]?.items ?? []).map(\.base))
            let older = ChatItem.parse(value["items"].array).filter { !have.contains($0.base) }
            chats[botId]?.items.insert(contentsOf: older, at: 0)
            chats[botId]?.cursor = value["cursor"].string
        } catch {
            banner = error.localizedDescription
        }
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let botId = selectedBotId, !trimmed.isEmpty else { return }
        let local = ChatItem(localUser: trimmed)
        chats[botId, default: ChatBuffer()].items.append(local)
        await deliver(local, botId: botId)
    }

    private func deliver(_ local: ChatItem, botId: String) async {
        do {
            try await client.call("send", ["sessionId": botId, "text": local.text])
            await loadChat(botId, quiet: true)
        } catch {
            // 没发出去：撤掉气泡，把文字放回输入框（不会覆盖用户新写的草稿），不自动重发
            chats[botId]?.items.removeAll { $0.id == local.id }
            restoredDraft = RestoredDraft(botId: botId, text: local.text)
            banner = "发送失败，内容已放回输入框：\(error.localizedDescription)"
        }
    }

    // MARK: 停止
    /// 与网页端一致：DSH 的 `session/cancel`。界面先落到“已停止”，再和服务器对账；没送达要明说。
    func stop(_ botId: String) async {
        working[botId] = nil
        stoppedAt[botId] = Date()
        hapticImpact()
        do {
            try await client.dshCall("session/cancel", args: ["request": ["sessionId": botId]])
        } catch {
            stoppedAt[botId] = nil
            banner = "停止请求没送达，任务可能仍在运行"
            await refresh()
        }
        try? await Task.sleep(for: .seconds(4))
        if let at = stoppedAt[botId], Date().timeIntervalSince(at) >= 3.9 { stoppedAt[botId] = nil }
    }

    private func hapticImpact() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }

    /// 其他 Bot（不含当前）里有多少在等批准或回答，用于顶部状态条。
    func otherAttention(excluding current: String) -> Int {
        Set(approvals.map(\.botId)).union(questions.keys).filter { $0 != current }.count
    }

    // MARK: 审批 / 提问
    func answer(_ approval: Approval, allow: Bool) async {
        do {
            if approval.answerable {
                try await client.call("approval-answer", ["id": approval.id, "choice": allow ? "allow" : "reject"])
            } else if let event = eventFor(approval) {
                try await events.answer(event, allow: allow)
                eventApprovals[approval.botId]?.removeAll { $0.eventId == event.eventId }
            } else {
                banner = "这个审批还没有同步到手机，请稍后再试或在网页端处理"
                return
            }
            approvals.removeAll { $0.id == approval.id }
        } catch {
            banner = error.localizedDescription
            await refresh()
        }
    }

    func answer(_ question: Question, selected: [String], custom: String = "") async {
        questions[question.sessionId] = nil
        do {
            try await client.call("answer-question", [
                "sessionId": question.sessionId, "questionId": question.id,
                "answer": ["selected": selected, "custom": custom],
            ])
            if let id = selectedBotId { await loadChat(id, quiet: true) }
        } catch { banner = error.localizedDescription; await refresh() }
    }

    // MARK: Bot 管理
    func createBot(name: String, role: String, model: String) async -> Bool {
        var payload: [String: Any] = ["name": name]
        if !role.isEmpty { payload["role"] = role }
        if !model.isEmpty { payload["model"] = model }
        do {
            let value = try await client.call("create-bot", payload)
            revision = -1
            await refresh()
            if let id = value["id"].string { select(id) }
            return true
        } catch {
            banner = error.localizedDescription
            return false
        }
    }

    // MARK: 单个 Bot 的设置
    /// `patch` 只放改动的字段：name / role / instructions / color / avatar / model / effort / workDir / permission。
    func updateBot(_ id: String, _ patch: [String: Any]) async throws {
        guard !patch.isEmpty else { return }
        try await client.call("update-bot", ["id": id].merging(patch) { $1 })
        revision = -1
        await refresh()
    }

    func duplicateBot(_ id: String) async throws {
        let value = try await client.call("duplicate-bot", ["id": id])
        revision = -1
        await refresh()
        if let newId = value["id"].string { select(newId) }
    }

    func deleteBot(_ id: String) async throws {
        try await client.call("delete-bot", ["id": id])
        chats[id] = nil
        previews[id] = nil
        chatOpen = false
        revision = -1
        await refresh()
    }

    func setMain(_ id: String, main: Bool, replace: String? = nil) async throws {
        var payload: [String: Any] = ["id": id, "main": main]
        if let replace { payload["replace"] = replace }
        try await client.call("set-main", payload)
        revision = -1
        await refresh()
    }

    func folders() async throws -> (team: String, list: [FolderOption]) {
        let value = try await client.call("folders", [:])
        let list = value["folders"].array.map { FolderOption(path: $0["path"].string ?? "", title: $0["title"].string ?? ($0["path"].string ?? "")) }
        return (value["team"].string ?? "", list)
    }

    func memory(_ botId: String) async throws -> MemoryView {
        let value = try await client.call("memory-view", ["botId": botId])
        return MemoryView(entries: value["entries"].array.map(MemoryEntry.init), summary: value["summary"]["text"].string ?? "", summarizing: value["summarizing"].bool ?? false)
    }

    func forgetMemory(_ botId: String, _ entry: MemoryEntry) async throws -> MemoryView {
        let value = try await client.call("memory-forget", ["botId": botId, "scope": entry.scope, "topic": entry.topic, "text": entry.text])
        return MemoryView(entries: value["entries"].array.map(MemoryEntry.init), summary: value["summary"]["text"].string ?? "", summarizing: value["summarizing"].bool ?? false)
    }

    func schedules() async throws -> (available: Bool, tasks: [ScheduleTask]) {
        let value = try await client.call("schedules", [:])
        return (value["available"].bool ?? false, value["tasks"].array.map(ScheduleTask.init))
    }

    func createSchedule(botId: String, title: String, prompt: String, when: [String: Any]) async throws {
        try await client.call("schedule-create", ["target": botId, "title": title, "prompt": prompt, "when": when])
    }

    func deleteSchedule(_ task: ScheduleTask) async throws {
        try await client.call("schedule-delete", ["sessionId": task.sessionId, "id": task.id])
    }

    func usage() async throws -> UsageReport {
        UsageReport(try await client.call("usage", ["timeZone": TimeZone.current.identifier]))
    }

    func modelLabel(_ ref: String) -> String {
        models.first { $0.ref == ref }?.name ?? ref.split(separator: "/").last.map(String.init) ?? ref
    }
}

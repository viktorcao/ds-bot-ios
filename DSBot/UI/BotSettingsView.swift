import SwiftUI

/// 单个 Bot 的设置：资料、头像、模型与思考等级、权限、工作文件夹、说明、记忆、定时任务、主 Bot、复制与删除。
struct BotSettingsView: View {
    @Environment(TeamStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let botId: String

    @State private var name = ""
    @State private var role = ""
    @State private var instructions = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var permission = ""
    @State private var workDir = ""
    @State private var color = ""
    @State private var shape = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @State private var folderOptions: [FolderOption] = []
    @State private var teamFolder = ""
    @State private var showAvatar = false
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @State private var memoryCount: Int?

    private var bot: Bot? { store.bots.first { $0.id == botId } }
    private var isMain: Bool { store.mainBotIds.contains(botId) }
    private var currentModel: ModelOption? { store.models.first { $0.ref == (model.isEmpty ? store.defaultModel : model) } }

    private var patch: [String: Any] {
        guard let bot, loaded else { return [:] }
        var p: [String: Any] = [:]
        if name.trimmingCharacters(in: .whitespaces) != bot.name { p["name"] = name.trimmingCharacters(in: .whitespaces) }
        if role != bot.role { p["role"] = role }
        if instructions != bot.instructions { p["instructions"] = instructions }
        if model != bot.model { p["model"] = model }
        if effort != bot.effort { p["effort"] = effort }
        if permission != (bot.permission ?? "") { p["permission"] = permission }
        if workDir != (bot.workDir ?? "") { p["workDir"] = workDir }
        if color != bot.color { p["color"] = color }
        if shape != bot.shape { p["avatar"] = ["shape": shape] }
        return p
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let bot {
                    VStack(alignment: .leading, spacing: 22) {
                        header(bot)
                        profile
                        modelSection
                        permissionSection
                        folderSection
                        instructionSection
                        memorySection
                        scheduleSection
                        mainSection
                        manageSection(bot)
                        if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                    }
                    .padding(16)
                } else {
                    ProgressView().padding(40)
                }
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { if patch.isEmpty { dismiss() } else { confirmDiscard = true } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { Task { await save() } }
                        .disabled(patch.isEmpty || saving)
                        .accessibilityIdentifier("saveBotSettings")
                }
            }
            .interactiveDismissDisabled(!patch.isEmpty)   // 有未保存的修改时，下滑不能直接关掉
            .confirmationDialog("放弃未保存的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
            .sheet(isPresented: $showAvatar) {
                AvatarEditor(shape: $shape, color: $color)
            }
            .confirmationDialog("删除 \(bot?.name ?? "")？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { Task { await delete() } }
            } message: { Text("它的对话和记忆会一并移除，无法恢复。") }
        }
        .presentationDetents([.large])
        .task { await load() }
    }

    // MARK: 区块
    private func header(_ bot: Bot) -> some View {
        HStack(spacing: 14) {
            Button { showAvatar = true } label: {
                ZStack(alignment: .bottomTrailing) {
                    CharacterView(shape: shape, color: color).frame(width: 76, height: 76)
                    Image(systemName: "pencil").font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26).background(Theme.surface, in: Circle())
                        .overlay(Circle().stroke(Theme.separator, lineWidth: 1))
                }
            }
            .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 3) {
                Text(name.isEmpty ? bot.name : name).font(.system(size: 22, weight: .bold))
                Text([role, isMain ? "主 Bot" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
    }

    private var profile: some View {
        Section2("资料") {
            row("名字") { TextField("名字", text: $name).multilineTextAlignment(.trailing).accessibilityIdentifier("botNameField") }
            Divider().overlay(Theme.separator)
            row("标签", hint: "可选，显示在名字下方。") { TextField("例如：Chief of Staff", text: $role).multilineTextAlignment(.trailing).accessibilityIdentifier("botRoleField") }
        }
    }

    private var modelSection: some View {
        Section2("模型") {
            row("模型", hint: "这个 Bot 的每条消息都用它。") {
                Menu {
                    Button("默认（\(store.modelLabel(store.defaultModel))）") { model = ""; effort = "" }
                    ForEach(store.models) { option in
                        Button { model = option.ref; if !option.efforts.contains(effort) { effort = option.efforts.contains("high") ? "high" : (option.efforts.first ?? "") } } label: {
                            Text(option.name + (option.provider.isEmpty ? "" : " · \(option.provider)"))
                        }
                    }
                } label: {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(currentModel?.name ?? store.modelLabel(model)).font(.system(size: 15, weight: .medium)).lineLimit(1)
                        Text([currentModel?.provider ?? "", effort.isEmpty ? "" : effort.capitalized].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12))
                }
                .foregroundStyle(Theme.text)
            }
            if let efforts = currentModel?.efforts, !efforts.isEmpty {
                Divider().overlay(Theme.separator)
                row("思考等级") {
                    Picker("思考等级", selection: $effort) {
                        ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 220)
                }
            }
        }
    }

    private var permissionSection: some View {
        Section2("权限") {
            Picker("权限", selection: $permission) {
                ForEach(store.permissionOptions) { option in Text(option.label).tag(option.value) }
            }
            .pickerStyle(.segmented)
            .padding(12)
            if permission == "danger-full-access" {
                Text("完全权限：这个 Bot 可以读写服务器上运行 DSH 的用户能访问的任何位置，并执行任意命令。")
                    .font(.footnote).foregroundStyle(Theme.danger).padding([.horizontal, .bottom], 12)
            }
        }
    }

    private var folderSection: some View {
        Section2("工作文件夹") {
            row("文件夹") {
                Menu {
                    Button("总工作区") { workDir = "" }
                    ForEach(folderOptions) { folder in Button(folder.title) { workDir = folder.path } }
                } label: {
                    HStack(spacing: 6) {
                        Text(workDir.isEmpty ? "总工作区" : (folderOptions.first { $0.path == workDir }?.title ?? (workDir as NSString).lastPathComponent)).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12))
                }.foregroundStyle(Theme.text)
            }
        }
    }

    private var instructionSection: some View {
        Section2("说明") {
            VStack(alignment: .leading, spacing: 8) {
                Text("这个 Bot 做什么").font(.system(size: 16, weight: .medium))
                Text("它在团队里的分工，会写进 Bot 的系统提示词。").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $instructions)
                    .font(.system(size: 15)).scrollContentBackground(.hidden)
                    .frame(minHeight: 130)
                    .padding(8).background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("instructionsEditor")
            }.padding(14)
        }
    }

    private var memorySection: some View {
        Section2("记忆") {
            NavigationLink { MemoryScreen(botId: botId) } label: {
                HStack {
                    Text(memoryCount.map { "\($0) 条" } ?? "—").font(.system(size: 16))
                    Spacer()
                    Text("管理").foregroundStyle(Theme.textSecondary)
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }.padding(14)
            }.foregroundStyle(Theme.text)
        }
    }

    private var scheduleSection: some View {
        Section2("定时任务") {
            NavigationLink { SchedulesScreen(botId: botId) } label: {
                HStack {
                    Image(systemName: "plus").frame(width: 24)
                    Text("管理 / 新建任务").font(.system(size: 16))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }.padding(14)
            }.foregroundStyle(Theme.text)
        }
    }

    @ViewBuilder private var mainSection: some View {
        Section2("主 Bot") {
            VStack(alignment: .leading, spacing: 10) {
                if isMain {
                    Text("这是唯一的主 Bot。要把主 Bot 交给别的 Bot，请在下面选择。").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    Menu("更换主 Bot") {
                        ForEach(store.bots.filter { $0.id != botId }) { other in
                            Button(other.name) { Task { await run { try await store.setMain(other.id, main: true, replace: botId) } } }
                        }
                    }
                    .font(.system(size: 15, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.surfaceHigh, in: Capsule()).foregroundStyle(Theme.text)
                } else {
                    Text("把这个 Bot 设为主 Bot：它负责管理团队、创建 Bot 和群聊。").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    Button("设为主 Bot") { Task { await run { try await store.setMain(botId, main: true, replace: store.mainBotIds.first) } } }
                        .font(.system(size: 15, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Theme.surfaceHigh, in: Capsule()).foregroundStyle(Theme.text)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func manageSection(_ bot: Bot) -> some View {
        Section2("管理") {
            Button { Task { await run { try await store.duplicateBot(botId); dismiss() } } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("复制一份").font(.system(size: 16, weight: .medium))
                        Text("复制分工和模型，记忆从零开始。").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }.padding(14)
            }.foregroundStyle(Theme.text).accessibilityIdentifier("duplicateBotButton")
            if !isMain {
                Divider().overlay(Theme.separator)
                Button(role: .destructive) { confirmDelete = true } label: {
                    HStack { Text("删除 Bot").font(.system(size: 16, weight: .medium)); Spacer() }.padding(14)
                }.accessibilityIdentifier("deleteBotButton")
            }
        }
    }

    // MARK: 行为
    private func load() async {
        guard !loaded, let bot else { return }
        name = bot.name; role = bot.role; instructions = bot.instructions
        model = bot.model; effort = bot.effort
        permission = bot.permission ?? store.defaultPermission
        workDir = bot.workDir ?? ""
        color = bot.color; shape = bot.shape
        loaded = true
        if let result = try? await store.folders() { folderOptions = result.list; teamFolder = result.team }
        if let memory = try? await store.memory(botId) { memoryCount = memory.entries.count }
    }

    private func save() async {
        saving = true; defer { saving = false }
        var body = patch
        // 权限与默认值相同且 Bot 本来没设置时不必提交
        if body["permission"] as? String == store.defaultPermission && bot?.permission == nil { body["permission"] = nil }
        await run { try await store.updateBot(botId, body); hapticTap(.medium); dismiss() }
    }

    private func delete() async {
        await run { try await store.deleteBot(botId); if store.selectedBotId == botId { store.selectedBotId = store.mainBotIds.first ?? store.bots.first?.id }; dismiss() }
    }

    private func run(_ work: () async throws -> Void) async {
        error = nil
        do { try await work() } catch { self.error = error.localizedDescription }
    }

    // MARK: 小组件
    private func row<Content: View>(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .medium))
                if let hint { Text(hint).font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
            }
            Spacer(minLength: 8)
            content()
        }.padding(14)
    }
}

/// 带标题的圆角分组卡片
struct Section2<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 18, weight: .bold)).padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.separator, lineWidth: 1))
        }
    }
}

/// 选择头像形状与颜色（20 种形状 × 19 种颜色，与网页端一致）。
struct AvatarEditor: View {
    @Binding var shape: String
    @Binding var color: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    CharacterView(shape: shape, color: color).frame(width: 110, height: 110).padding(.top, 8)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                        ForEach(CharacterArt.shapeIds, id: \.self) { id in
                            Button { shape = id; hapticTap() } label: {
                                CharacterView(shape: id, color: color).padding(8)
                                    .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                                    .background(shape == id ? Theme.surfaceHigh : Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(shape == id ? Theme.text.opacity(0.7) : .clear, lineWidth: 1.5))
                            }
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 7), spacing: 12) {
                        ForEach(CharacterArt.colorIds, id: \.self) { id in
                            Button { color = id; hapticTap() } label: {
                                Circle().fill(CharacterArt.color(id, dark: true)).frame(height: 34)
                                    .overlay(Circle().stroke(Theme.text, lineWidth: color == id ? 2.5 : 0).padding(-4))
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: 记忆
struct MemoryScreen: View {
    @Environment(TeamStore.self) private var store
    let botId: String
    @State private var memory: MemoryView?
    @State private var error: String?
    @State private var pendingForget: MemoryEntry?

    var body: some View {
        List {
            if let memory {
                if !memory.summary.isEmpty {
                    Section("摘要") { Text(memory.summary).font(.system(size: 14)).foregroundStyle(Theme.textSecondary) }
                }
                Section("\(memory.entries.count) 条记忆") {
                    if memory.entries.isEmpty { Text("还没有记忆。Bot 会在对话空闲时整理要记住的内容。").foregroundStyle(Theme.textSecondary) }
                    ForEach(memory.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.topic.isEmpty ? "未分类" : entry.topic).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                                if entry.scope != "own" { Text("· 团队").font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                                Spacer()
                                Text(entry.added).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                            Text(entry.text).font(.system(size: 15))
                        }
                        .swipeActions { Button("忘掉", role: .destructive) { pendingForget = entry } }
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(Theme.danger)
            } else { ProgressView() }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("记忆").navigationBarTitleDisplayMode(.inline)
        .task { do { memory = try await store.memory(botId) } catch { self.error = error.localizedDescription } }
        .confirmationDialog("忘掉这条记忆？", isPresented: Binding(get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } }), titleVisibility: .visible) {
            Button("忘掉", role: .destructive) {
                guard let entry = pendingForget else { return }
                Task { do { memory = try await store.forgetMemory(botId, entry) } catch { self.error = error.localizedDescription } }
            }
        }
    }
}

// MARK: 定时任务
struct SchedulesScreen: View {
    @Environment(TeamStore.self) private var store
    /// nil = 账号面板里的“全部定时任务”（只查看和删除，新建要进具体 Bot）
    let botId: String?
    @State private var tasks: [ScheduleTask] = []
    @State private var available = true
    @State private var error: String?
    @State private var showNew = false
    private var botName: String { store.bots.first { $0.id == botId }?.name ?? "" }
    private var mine: [ScheduleTask] { botId == nil ? tasks : tasks.filter { $0.owner.isEmpty || $0.owner == botName } }

    var body: some View {
        List {
            if !available { Text("DSH 里没有开启自动化任务").foregroundStyle(Theme.textSecondary) }
            ForEach(mine) { task in
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).font(.system(size: 16, weight: .medium))
                    if !task.when.isEmpty { Text(task.when + (botId == nil && !task.owner.isEmpty ? " · \(task.owner)" : "")).font(.system(size: 13)).foregroundStyle(Theme.accent) }
                    Text(task.prompt).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                .swipeActions { Button("删除", role: .destructive) { Task { try? await store.deleteSchedule(task); await reload() } } }
            }
            if available && mine.isEmpty { Text("还没有定时任务").foregroundStyle(Theme.textSecondary) }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("定时任务").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if botId != nil { ToolbarItem(placement: .primaryAction) { Button { showNew = true } label: { Image(systemName: "plus") }.disabled(!available) } }
        }
        .sheet(isPresented: $showNew) { if let botId { NewScheduleSheet(botId: botId) { await reload() }.environment(store) } }
        .task { await reload() }
    }

    private func reload() async {
        do { let r = try await store.schedules(); tasks = r.tasks; available = r.available } catch { self.error = error.localizedDescription }
    }
}

struct NewScheduleSheet: View {
    @Environment(TeamStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let botId: String
    var done: () async -> Void
    @State private var title = ""
    @State private var prompt = ""
    @State private var kind = "daily"
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var date = Date().addingTimeInterval(3600)
    @State private var minutes = 60
    @State private var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("名称", text: $title)
                    TextField("让 Bot 做什么", text: $prompt, axis: .vertical).lineLimit(3...8)
                }
                Section("什么时候") {
                    Picker("重复", selection: $kind) {
                        Text("每天").tag("daily"); Text("每周").tag("weekly"); Text("间隔").tag("every"); Text("一次").tag("at")
                    }.pickerStyle(.segmented)
                    switch kind {
                    case "daily": DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                    case "weekly":
                        DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                        HStack { ForEach(Array(["一", "二", "三", "四", "五", "六", "日"].enumerated()), id: \.offset) { index, label in
                            Button { if weekdays.contains(index + 1) { weekdays.remove(index + 1) } else { weekdays.insert(index + 1) } } label: {
                                Text(label).frame(width: 32, height: 32)
                                    .background(weekdays.contains(index + 1) ? Theme.accent : Theme.surfaceHigh, in: Circle())
                                    .foregroundStyle(weekdays.contains(index + 1) ? .white : Theme.text)
                            }.buttonStyle(.plain)
                        } }
                    case "every": Stepper("每 \(minutes) 分钟", value: $minutes, in: 1...10080, step: 15)
                    default: DatePicker("日期与时间", selection: $date, in: Date()...)
                    }
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .navigationTitle("新建任务").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { Task { await create() } }.disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func create() async {
        busy = true; defer { busy = false }
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        var when: [String: Any] = ["kind": kind, "timeZone": TimeZone.current.identifier]
        switch kind {
        case "daily": when["time"] = fmt.string(from: time)
        case "weekly": when["time"] = fmt.string(from: time); when["weekdays"] = weekdays.sorted()
        case "every": when["minutes"] = minutes
        default: when["at"] = ISO8601DateFormatter().string(from: date)
        }
        do {
            try await store.createSchedule(botId: botId, title: title.trimmingCharacters(in: .whitespaces), prompt: prompt.trimmingCharacters(in: .whitespaces), when: when)
            await done(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

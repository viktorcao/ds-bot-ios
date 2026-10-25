import SwiftUI

struct NewBotSheet: View {
    @Environment(TeamStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var onCreated: () -> Void = {}
    @State private var name = ""
    @State private var role = ""
    @State private var model = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") { TextField("例如：邮件助理", text: $name).accessibilityIdentifier("newBotName") }
                Section("职责（可选）") { TextField("例如：整理每天的邮件", text: $role) }
                Section("模型") {
                    Picker("模型", selection: $model) {
                        Text("默认（\(store.modelLabel(store.defaultModel))）").tag("")
                        ForEach(store.models) { Text($0.name).tag($0.ref) }
                    }
                }
            }
            .navigationTitle("新建 Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        busy = true
                        Task {
                            if await store.createBot(name: name.trimmingCharacters(in: .whitespaces), role: role, model: model) { dismiss(); onCreated() }
                            busy = false
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    .accessibilityIdentifier("newBotCreate")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 账号与设置面板（参照 Grok Bot）：账号、统计与任务、通知外观缓存、退出登录
struct SettingsSheet: View {
    @Environment(TeamStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dsbot.appearance") private var appearance = "system"
    @AppStorage("dsbot.notify") private var notify = true
    @AppStorage("dsbot.cacheLimitMB") private var cacheLimit = 50
    @State private var cacheBytes = 0
    @State private var confirmLogout = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Text(String(store.config.user.first ?? "?").uppercased()).font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44).background(Theme.surfaceHigh, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.config.user.isEmpty ? "未登录" : store.config.user).font(.system(size: 17, weight: .medium))
                            Text(store.config.baseURL?.host ?? store.config.url).font(.footnote).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(store.offlineMessage == nil ? "已连接" : "离线").font(.footnote)
                            .foregroundStyle(store.offlineMessage == nil ? Color.green : Color.orange)
                    }
                    NavigationLink { UsageView() } label: { Label("用量", systemImage: "chart.bar.xaxis") }.accessibilityIdentifier("usageLink")
                    NavigationLink { SchedulesScreen(botId: nil) } label: { Label("定时任务", systemImage: "clock") }.accessibilityIdentifier("schedulesLink")
                    if !store.rooms.isEmpty {
                        NavigationLink { RoomsScreen() } label: { LabeledContent { Text("\(store.rooms.count)").foregroundStyle(Theme.textSecondary) } label: { Label("群聊", systemImage: "person.3") } }
                    }
                }
                Section {
                    Toggle("审批和完成提醒", isOn: $notify)
                        .onChange(of: notify) { _, on in if on { Task { await Notifier.requestIfNeeded() } } else { Notifier.clearDelivered() } }
                } footer: {
                    Text("没有推送服务，所以只在 App 打开、或刚切到后台的约 30 秒内能提醒你；之后需要回到 App 才会看到。")
                }
                Section("外观") {
                    Picker("主题", selection: $appearance) {
                        Text("深色").tag("dark"); Text("浅色").tag("light"); Text("跟随系统").tag("system")
                    }.pickerStyle(.segmented)
                }
                Section {
                    Picker("缓存上限", selection: $cacheLimit) {
                        ForEach(ChatCache.limitOptions, id: \.self) { Text("\($0) MB").tag($0) }
                    }
                    LabeledContent("已缓存", value: ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))
                    Button("清除缓存", role: .destructive) { ChatCache.clear(); cacheBytes = ChatCache.totalBytes() }
                } header: { Text("聊天缓存") } footer: {
                    Text("只保存每个 Bot 最近的内容，超过上限时先丢最久没打开的 Bot。断网或刚启动时先显示缓存，再同步。")
                }
                Section {
                    Button("退出登录", role: .destructive) { confirmLogout = true }.accessibilityIdentifier("logoutButton")
                }
                Section { LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { cacheBytes = ChatCache.totalBytes() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭").accessibilityIdentifier("settingsClose")
                }
            }
            .confirmationDialog("退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) { store.logout(); dismiss() }
            } message: { Text("会清除本机的账号密码、聊天缓存和未发送的草稿。") }
        }
        .presentationDetents([.large])
    }
}

private struct RoomsScreen: View {
    @Environment(TeamStore.self) private var store

    var body: some View {
        List(store.rooms) { room in
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name).font(.system(size: 16, weight: .medium))
                Text("\(room.memberCount) 位成员 · 群聊请在网页端查看").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle("群聊").navigationBarTitleDisplayMode(.inline)
    }
}

import SwiftUI

/// Bot 资料页（参照 Grok Bot）：大头像、编辑入口、一组带状态的行。编辑进入原来的完整设置。
struct BotProfileView: View {
    @Environment(TeamStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let botId: String
    @State private var showEdit = false
    @State private var scheduleCount: Int?

    private var bot: Bot? { store.bots.first { $0.id == botId } }

    var body: some View {
        NavigationStack {
            Group {
                if let bot {
                    Form {
                        Section {
                            VStack(spacing: 10) {
                                AvatarView(bot: bot, size: 112, isMain: store.mainBotIds.contains(bot.id), badge: true)
                                Text(bot.name).font(.system(size: 24, weight: .bold))
                                if !bot.role.isEmpty { Text(bot.role).font(.subheadline).foregroundStyle(Theme.textSecondary) }
                                Button { showEdit = true } label: {
                                    Text("编辑").font(.system(size: 15, weight: .medium))
                                        .padding(.horizontal, 22).padding(.vertical, 8).background(Theme.surfaceHigh, in: Capsule())
                                }
                                .buttonStyle(.pressable).foregroundStyle(Theme.text).accessibilityIdentifier("editBotButton")
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .listRowBackground(Color.clear)
                        }
                        Section {
                            NavigationLink { SchedulesScreen(botId: bot.id) } label: {
                                LabeledContent {
                                    Text(scheduleCount.map { $0 == 0 ? "无" : "\($0) 个" } ?? "").foregroundStyle(Theme.textSecondary)
                                } label: { Label("定时任务", systemImage: "clock") }
                            }
                            LabeledContent { Text(store.modelLabel(bot.model.isEmpty ? store.defaultModel : bot.model) + (bot.effort.isEmpty ? "" : " · \(bot.effort)")).foregroundStyle(Theme.textSecondary) }
                                label: { Label("模型", systemImage: "cpu") }
                            LabeledContent { Text(permissionLabel(bot)).foregroundStyle(Theme.textSecondary) }
                                label: { Label("权限", systemImage: "lock.shield") }
                            LabeledContent { Text(folderLabel(bot)).foregroundStyle(Theme.textSecondary) }
                                label: { Label("工作目录", systemImage: "folder") }
                            LabeledContent {
                                Text(store.working[bot.id].map { $0.tool.isEmpty ? "工作中" : "使用 \($0.tool)" } ?? "空闲").foregroundStyle(Theme.textSecondary)
                            } label: { Label("状态", systemImage: "desktopcomputer") }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭")
                }
            }
            .task { await loadSchedules() }
            .onChange(of: bot == nil) { _, gone in if gone { dismiss() } }
            .onChange(of: store.selectedBotId) { _, _ in dismiss() }   // 复制出新 Bot 并切过去后，关掉旧资料页
            .sheet(isPresented: $showEdit) { BotSettingsView(botId: botId).environment(store) }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("botProfile")
    }

    private func permissionLabel(_ bot: Bot) -> String {
        let value = bot.permission ?? store.defaultPermission
        return store.permissionOptions.first { $0.value == value }?.label ?? value
    }

    private func folderLabel(_ bot: Bot) -> String {
        guard let dir = bot.workDir, !dir.isEmpty else { return "默认" }
        return (dir as NSString).lastPathComponent
    }

    private func loadSchedules() async {
        guard let bot, let result = try? await store.schedules() else { return }
        scheduleCount = result.tasks.filter { $0.owner.isEmpty || $0.owner == bot.name }.count
    }
}

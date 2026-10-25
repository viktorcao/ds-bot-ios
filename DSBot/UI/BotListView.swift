import SwiftUI

/// 首页：整页 Bot 列表（参照 Grok Bot）。大头像 + 名称 + 标签 + 最后一条消息 + 时间；
/// 左上角账号，右上角新建，底部悬浮搜索。
struct BotListView: View {
    @Environment(TeamStore.self) private var store
    @State private var showNewBot = false
    @State private var showSettings = false
    @State private var query = ""
    @FocusState private var searching: Bool

    /// 最近有消息的排前面；还没有消息的按创建时间排在后面
    private var sortedBots: [Bot] {
        let list = store.bots.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.role.localizedCaseInsensitiveContains(query)
        }
        return list.sorted { a, b in
            let wa = store.working[a.id] != nil, wb = store.working[b.id] != nil
            if wa != wb { return wa }   // 正在工作的排最前
            let ta = store.previews[a.id]?.time ?? .distantPast, tb = store.previews[b.id]?.time ?? .distantPast
            return ta != tb ? ta > tb : a.createdAt > b.createdAt
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sortedBots) { bot in row(bot) }
                    if sortedBots.isEmpty && !query.isEmpty {
                        Text("没有匹配的 Bot").font(.footnote).foregroundStyle(Theme.textSecondary).padding(.top, 40)
                    }
                }
                .padding(.bottom, 88)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await store.refresh() }
            .overlay(alignment: .bottom) { searchBar }
        }
        .background(Theme.background)
        .sheet(isPresented: $showNewBot) { NewBotSheet().environment(store) }
        .sheet(isPresented: $showSettings) { SettingsSheet().environment(store) }
    }

    private var topBar: some View {
        HStack {
            Button { showSettings = true } label: {
                ZStack(alignment: .bottomTrailing) {
                    Text(String(store.config.user.first ?? "?").uppercased())
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44).background(Theme.surface, in: Circle())
                        .overlay(Circle().stroke(Theme.separator, lineWidth: 1))
                    // 状态点：离线是橙色，有 Bot 在等你是蓝色
                    if store.offlineMessage != nil {
                        Circle().fill(Color.orange).frame(width: 11, height: 11).overlay(Circle().stroke(Theme.background, lineWidth: 2))
                    }
                }
            }
            .buttonStyle(.pressable).foregroundStyle(Theme.text)
            .accessibilityIdentifier("appSettingsButton").accessibilityLabel("账号与设置")
            Spacer()
            if store.offlineMessage != nil && !store.bots.isEmpty {
                Label("离线 · 正在重连", systemImage: "wifi.slash").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityIdentifier("offlineBadge")
                Spacer()
            }
            Button { showNewBot = true } label: {
                Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44).background(Theme.surface, in: Circle())
                    .overlay(Circle().stroke(Theme.separator, lineWidth: 1))
            }
            .buttonStyle(.pressable).foregroundStyle(Theme.text)
            .accessibilityIdentifier("newBotButton").accessibilityLabel("新建 Bot")
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            TextField("搜索", text: $query).focused($searching).submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary) }
                    .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 16).frame(height: 48)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.separator, lineWidth: 1))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func row(_ bot: Bot) -> some View {
        let isMain = store.mainBotIds.contains(bot.id)
        let preview = store.previews[bot.id]
        let activity = store.working[bot.id]
        return Button {
            hapticTap()
            searching = false
            store.select(bot.id)
        } label: {
            HStack(spacing: 14) {
                AvatarView(bot: bot, size: 52, isMain: isMain, badge: true)
                    .overlay(alignment: .bottomTrailing) {
                        if activity != nil {
                            Circle().fill(Color.green).frame(width: 13, height: 13)
                                .overlay(Circle().stroke(Theme.background, lineWidth: 2.5))
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(bot.name).font(.system(size: 17, weight: .medium)).lineLimit(1)
                        if !bot.role.isEmpty {
                            Text(bot.role).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 2).background(Theme.surface, in: Capsule())
                        }
                        Spacer(minLength: 0)
                        if let preview { Text(Self.timeLabel(preview.time)).font(.system(size: 13)).foregroundStyle(Theme.textSecondary) }
                    }
                    HStack(spacing: 6) {
                        Text(activity.map { $0.tool.isEmpty ? "正在回复" : "正在使用 \($0.tool)" } ?? preview?.text ?? store.modelLabel(bot.model))
                            .font(.system(size: 15)).lineLimit(1)
                            .foregroundStyle(activity == nil ? Theme.textSecondary : Theme.accent)
                        Spacer(minLength: 0)
                        // 优先级：等审批 > 等回答 > 正在工作 > 跑完未读
                        if store.approvals.contains(where: { $0.botId == bot.id }) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        } else if store.questions[bot.id] != nil {
                            Image(systemName: "questionmark.bubble.fill").foregroundStyle(Theme.accent)
                        } else if store.unread.contains(bot.id) {
                            Circle().fill(Theme.accent).frame(width: 9, height: 9)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .foregroundStyle(Theme.text)
        .accessibilityIdentifier("botRow-\(bot.name)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusText(bot))
    }

    private func statusText(_ bot: Bot) -> String {
        if store.approvals.contains(where: { $0.botId == bot.id }) { return "等待批准" }
        if store.questions[bot.id] != nil { return "等待回答" }
        if store.working[bot.id] != nil { return "正在工作" }
        return store.unread.contains(bot.id) ? "有新回复" : ""
    }

    /// 今天显示时间，昨天、一周内显示星期，更早显示月日
    static func timeLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(date) { fmt.dateFormat = "HH:mm" }
        else if cal.isDateInYesterday(date) { return "昨天" }
        else if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day, days < 7 { fmt.dateFormat = "EEEE" }
        else { fmt.dateFormat = "M月d日" }
        return fmt.string(from: date)
    }
}

import SwiftUI

struct ChatView: View {
    @Environment(TeamStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let bot: Bot
    var back: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var showProfile = false
    @State private var confirmDelete = false
    @State private var showOptions = false
    @State private var atBottom = true
    @State private var unseen = 0
    @State private var animateInserts = false
    /// 状态接口先报“不忙了”、最终回复还在路上时，指示器多留一会儿，避免出现空白再突然弹出
    @State private var finishing = false

    private var buffer: ChatBuffer { store.chats[bot.id] ?? ChatBuffer() }
    private var activity: Activity? { store.working[bot.id] }
    private var stopped: Bool { store.stoppedAt[bot.id] != nil }
    private var myApprovals: [Approval] { store.approvals.filter { $0.botId == bot.id } }
    private var myQuestion: Question? { store.questions[bot.id] ?? store.questions.values.first { $0.sessionId == buffer.sessionId } }
    /// 别的 Bot 里有多少在等批准或回答（在工作的不提示，免得打扰）
    private var attention: Int { store.otherAttention(excluding: bot.id) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if buffer.cursor != nil {
                            Button { Task { await store.loadEarlier(bot.id) } } label: {
                                if buffer.loadingEarlier { ProgressView() } else { Text("加载更早的消息").font(.footnote) }
                            }
                            .buttonStyle(.pressable)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        if !buffer.loaded {
                            // 首次打开：给一个固定位置的加载指示；失败时给重试，而不是一片空白
                            VStack(spacing: 10) {
                                if store.offlineMessage != nil {
                                    Text("还没加载出来").font(.footnote).foregroundStyle(Theme.textSecondary)
                                    Button("重试") { Task { await store.loadChat(bot.id) } }.buttonStyle(.bordered)
                                } else {
                                    ProgressView()
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 200)
                            .accessibilityIdentifier("chatLoading")
                        }
                        if buffer.items.isEmpty && buffer.loaded && activity == nil {
                            EmptyChat(bot: bot, isMain: store.mainBotIds.contains(bot.id)) { prompt in draft = prompt; focused = true }
                        }
                        ForEach(buffer.items) { item in
                            VStack(spacing: 20) {
                                if let label = separators[item.id] {
                                    Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity)
                                }
                                MessageRow(item: item, bot: bot, turnText: activity == nil ? footers[item.id] : nil)
                            }
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 16)).combined(with: .scale(scale: 0.97, anchor: .bottomLeading)), removal: .opacity))
                        }
                        if let activity { RunIndicator(activity: activity, bot: bot).transition(.opacity) }
                        else if finishing { RunIndicator(activity: Activity(tool: ""), bot: bot).transition(.opacity) }
                        else if stopped { StoppedNote().transition(.opacity) }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { atBottom = true; unseen = 0 }
                            .onDisappear { atBottom = false }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 78)   // 给浮在上面的顶栏留位置；消息从玻璃顶栏下面滚过
                    .padding(.bottom, 12)
                    .animation(animateInserts ? .spring(response: 0.42, dampingFraction: 0.86) : nil, value: buffer.items.count)
                    .animation(.easeOut(duration: 0.2), value: finishing)
                    .animation(.easeOut(duration: 0.2), value: myApprovals.count)
                    .animation(.easeOut(duration: 0.2), value: activity == nil)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom {
                        Button {
                            hapticTap()
                            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold))
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().stroke(Theme.separator, lineWidth: 1))
                                .overlay(alignment: .topTrailing) {
                                    if unseen > 0 {
                                        Text("\(min(unseen, 99))").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                            .background(Theme.accent, in: Capsule()).offset(x: 6, y: -6)
                                    }
                                }
                        }
                        .buttonStyle(.pressable).foregroundStyle(Theme.text)
                        .accessibilityLabel(unseen > 0 ? "\(unseen) 条新消息，回到底部" : "回到底部")
                        .padding(.trailing, 16).padding(.bottom, 10).transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: unseen)
                // 只有用户本来就在底部时才自动跟随；翻看历史时不抢滚动，改为提示有新消息
                .onChange(of: buffer.items.last?.id) { old, new in
                    guard new != nil else { return }
                    if buffer.items.last?.kind == .bot { finishing = false }
                    if atBottom || buffer.items.last?.kind == .user { scroll(proxy) } else if old != nil { unseen += 1 }
                }
                .onChange(of: activity == nil) { _, idle in
                    if atBottom { scroll(proxy) }
                    // 正常结束（不是用户点了停止）：等回复落到列表里，最多留 2.5 秒
                    if idle && !stopped {
                        finishing = true
                        Task { try? await Task.sleep(for: .milliseconds(2500)); finishing = false }
                    } else { finishing = false }
                }
                .onChange(of: myApprovals.count) { _, _ in if atBottom { scroll(proxy) } else { unseen += 1 } }
                .onChange(of: focused) { _, isFocused in if isFocused { scroll(proxy) } }
                .onChange(of: bot.id) { _, _ in animateInserts = false; unseen = 0; scroll(proxy, animated: false); enableInsertAnimation() }
                .onAppear { enableInsertAnimation() }
            }
            if !myApprovals.isEmpty || myQuestion != nil {
                InteractionDock(approvals: myApprovals, question: myQuestion)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Composer(draft: $draft, focused: $focused, placeholder: "给 \(bot.name) 发消息", busy: activity != nil,
                     options: { showOptions = true },
                     send: {
                         let text = draft
                         draft = ""
                         hapticTap()
                         Task { await store.send(text) }
                     },
                     stop: { Task { await store.stop(bot.id) } })
        }
        .background(Theme.background)
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                header
                if attention > 0 { AttentionStrip(waiting: attention, action: back) }
            }
            .background(alignment: .top) {
                // 顶栏下面只有一层很淡的渐变：内容能透出来，但按钮不会和文字糊在一起
                LinearGradient(colors: [Theme.background.opacity(0.85), Theme.background.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 80).ignoresSafeArea(edges: .top).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = false }
        .animation(.easeOut(duration: 0.22), value: myApprovals.count)
        .animation(.easeOut(duration: 0.22), value: myQuestion?.id)
        .sheet(isPresented: $showOptions) { ComposerOptionsSheet(botId: bot.id).environment(store) }
        .onAppear { draft = Self.savedDraft(bot.id) }
        .onChange(of: bot.id) { old, new in Self.saveDraft(draft, for: old); draft = Self.savedDraft(new) }
        .onChange(of: draft) { _, new in Self.saveDraft(new, for: bot.id) }
        .onChange(of: store.restoredDraft) { _, restored in
            // 发送失败：文字放回输入框；输入框里已有新内容时接在后面，不覆盖
            guard let restored, restored.botId == bot.id else { return }
            draft = draft.isEmpty ? restored.text : draft + "\n\n" + restored.text
            store.restoredDraft = nil
        }
    }

    private static func savedDraft(_ id: String) -> String { UserDefaults.standard.string(forKey: "dsbot.draft.\(id)") ?? "" }
    private static func saveDraft(_ text: String, for id: String) {
        if text.isEmpty { UserDefaults.standard.removeObject(forKey: "dsbot.draft.\(id)") } else { UserDefaults.standard.set(text, forKey: "dsbot.draft.\(id)") }
    }

    /// 每一轮（两条用户消息之间）只在最后一条回复下放一次复制，内容是这一轮所有回复拼起来
    private var footers: [String: String] {
        var result: [String: String] = [:]
        var run: [ChatItem] = []
        func flush() { if let last = run.last { result[last.id] = run.map(\.text).joined(separator: "\n\n") }; run = [] }
        for item in buffer.items {
            switch item.kind {
            case .bot: run.append(item)
            case .user: flush()
            case .other: break
            }
        }
        flush()
        return result
    }

    /// 时间分隔：第一条、隔了 30 分钟以上、或跨天时，在那条消息前插一行居中的时间
    private var separators: [String: String] {
        var result: [String: String] = [:]
        var last: Date?
        for item in buffer.items where item.kind != .other && item.time.timeIntervalSince1970 > 946_684_800 {
            let continuing = last.map { item.time.timeIntervalSince($0) < 1800 && Calendar.current.isDate(item.time, inSameDayAs: $0) } ?? false
            if !continuing { result[item.id] = Self.separatorLabel(item.time) }
            last = item.time
        }
        return result
    }

    /// DateFormatter 创建很贵，而分隔标签每次重绘都要算：复用同一个（只在主线程用）
    private static let labelFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt
    }()

    private static func separatorLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let fmt = Self.labelFormatter
        fmt.dateFormat = "HH:mm"
        let time = fmt.string(from: date)
        if cal.isDateInToday(date) { return "今天 \(time)" }
        if cal.isDateInYesterday(date) { return "昨天 \(time)" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day, days < 7 {
            fmt.dateFormat = "EEEE HH:mm"; return fmt.string(from: date)
        }
        fmt.dateFormat = "M月d日 HH:mm"
        return fmt.string(from: date)
    }

    private func enableInsertAnimation() {
        // 首次载入的历史记录不做入场动画，之后新来的消息才有
        Task { try? await Task.sleep(for: .milliseconds(600)); animateInserts = true }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            atBottom = true; unseen = 0   // 回到底部的"回到底部"按钮不要因为长回复把锚点顶出屏幕而滞留
            if animated && !reduceMotion { withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            else { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Theme.separator, lineWidth: 1))
            }
            .buttonStyle(.pressable).foregroundStyle(Theme.text)
            .accessibilityIdentifier("backButton").accessibilityLabel("返回")
            Spacer(minLength: 0)
            Button { showProfile = true } label: {
                HStack(spacing: 8) {
                    AvatarView(bot: bot, size: 26)
                        .overlay(alignment: .bottomTrailing) {
                            if activity != nil {
                                Circle().fill(Color.green).frame(width: 9, height: 9).overlay(Circle().stroke(Theme.background, lineWidth: 1.5))
                            }
                        }
                    Text(bot.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                }
                .padding(.horizontal, 14).frame(height: 44)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Theme.separator, lineWidth: 1))
            }
            .buttonStyle(.pressable).foregroundStyle(Theme.text)
            .accessibilityIdentifier("botSettingsButton").accessibilityLabel("\(bot.name) 资料")
            Spacer(minLength: 0)
            Menu {
                Button { showProfile = true } label: { Label("查看资料", systemImage: "person.crop.circle") }
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Theme.separator, lineWidth: 1))
            }
            .foregroundStyle(Theme.text)
            .accessibilityIdentifier("botMenuButton").accessibilityLabel("更多")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .sheet(isPresented: $showProfile) { BotProfileView(botId: bot.id).environment(store) }
        .confirmationDialog("删除 \(bot.name)？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                let id = bot.id
                Task {
                    do { try await store.deleteBot(id) } catch { store.banner = error.localizedDescription }
                }
            }
        } message: { Text("它的对话和记忆会一并移除，无法恢复。") }
    }
}

// MARK: 顶部状态条：别的 Bot 在等你批准或回答时，当前页面也能看到
private struct AttentionStrip: View {
    let waiting: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text("\(waiting) 个 Bot 在等你").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.orange)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14).frame(minHeight: 36)
            .background(Color.orange.opacity(0.12), in: Capsule())
            .padding(.horizontal, 12).padding(.bottom, 4)
        }
        .buttonStyle(.pressable)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityIdentifier("attentionStrip")
    }
}

private struct MessageRow: View {
    @Environment(TeamStore.self) private var store
    let item: ChatItem
    let bot: Bot
    var turnText: String?
    @State private var copied = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack(spacing: 8) {
                Spacer(minLength: 56)
                if item.id.hasPrefix("local-") {
                    // 发送状态只占左侧空隙，不改变气泡宽度
                    ProgressView().controlSize(.small)
                }
                Text(item.text)
                    .font(.body).lineSpacing(3)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .foregroundStyle(bot.onTint)
                    .background(bot.tint, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contextMenu { copyButton }
                    .accessibilityIdentifier("userMessage")
            }

        case .bot:
            VStack(alignment: .leading, spacing: 4) {
                MarkdownView(text: item.text)
                    .font(.body).lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.trailing, 12)
                if let turnText {
                Button {
                    UIPasteboard.general.string = turnText
                    copied = true
                    hapticTap()
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13))
                        .frame(width: 44, height: 32, alignment: .leading)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.pressable)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel("复制")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("botMessage")
        case .other:
            if !item.text.isEmpty {
                Text(item.text).font(.footnote).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var copyButton: some View {
        Button { UIPasteboard.general.string = item.text } label: { Label("复制", systemImage: "doc.on.doc") }
    }
}

/// 运行中的唯一活动指示（参照 Grok Bot）：还没调用工具时是三个跳动的小点 + 轮换的词；
/// 调用工具时是小号头像 + 在做什么 + 灰色计时。都放在左侧，不改变消息宽度。
private struct RunIndicator: View {
    let activity: Activity
    let bot: Bot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let verbs = ["正在输入…", "正在推进…", "正在琢磨…"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = activity.since.map { context.date.timeIntervalSince($0) } ?? 0
            HStack(spacing: 10) {
                if activity.tool.isEmpty {
                    TypingDots(color: bot.tint, animate: !reduceMotion)
                    Text(Self.verbs[Int(elapsed / 4) % Self.verbs.count]).font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                } else {
                    AvatarView(bot: bot, size: 24)
                        .scaleEffect(reduceMotion ? 1 : (Int(elapsed) % 2 == 0 ? 1 : 0.92))
                        .animation(.easeInOut(duration: 0.6), value: Int(elapsed) % 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(activity.tool).font(.system(size: 15)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        if !activity.note.isEmpty { Text(activity.note).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                    }
                }
                if activity.since != nil {
                    Text("· \(elapsedText(elapsed))").font(.system(size: 13)).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.tool.isEmpty ? "正在思考" : "正在使用 \(activity.tool)")
        .accessibilityIdentifier("runIndicator")
    }
}

private struct TypingDots: View {
    let color: Color
    let animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !animate)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (sin(t * 5 - Double(i) * 0.9) + 1) / 2
                    Circle().fill(color).frame(width: 7, height: 7)
                        .opacity(animate ? 0.35 + 0.65 * phase : 0.8)
                        .offset(y: animate ? -3 * phase : 0)
                }
            }
            .frame(width: 30, height: 20)
        }
    }
}

private struct StoppedNote: View {
    var body: some View {
        Label("已停止", systemImage: "stop.circle").font(.footnote).foregroundStyle(Theme.textSecondary)
            .accessibilityIdentifier("stoppedNote")
    }
}

private struct EmptyChat: View {
    let bot: Bot
    let isMain: Bool
    var pick: (String) -> Void

    private var suggestions: [String] {
        isMain ? ["帮我建一个新的 Bot", "总结一下现在团队在做什么", "检查服务器的运行状态"]
               : ["你能帮我做什么？", "介绍一下你自己", "记住一件事"]
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 60)
            AvatarView(bot: bot, size: 84, isMain: isMain)
            Text("想让 \(bot.name) 做点什么？").font(.title3.weight(.semibold))
            if !bot.role.isEmpty { Text(bot.role).font(.subheadline).foregroundStyle(Theme.textSecondary) }
            VStack(spacing: 10) {
                ForEach(suggestions, id: \.self) { s in
                    Button { hapticTap(); pick(s) } label: {
                        Text(s).font(.subheadline).padding(.horizontal, 16).frame(minHeight: 44)
                            .background(Theme.surface, in: Capsule())
                            .overlay(Capsule().stroke(Theme.separator, lineWidth: 1))
                    }
                    .buttonStyle(.pressable).foregroundStyle(Theme.text)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 底部输入栏。空闲且没有内容时收成一个细胶囊（左右多留 20pt），聚焦、有文字或 Bot 在工作时展开，
/// 露出“+”选项和发送键。右侧按钮的位置是常驻的：空闲时是发送，Bot 在工作且没有草稿时变成停止（和网页端一致）。
/// 同一个 TextField 在收起/展开之间保持身份，所以不会丢焦点或输入法状态。
struct Composer: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let placeholder: String
    let busy: Bool
    var options: (() -> Void)? = nil
    var send: () -> Void
    var stop: () -> Void

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var showsStop: Bool { busy && !hasText }
    private var expanded: Bool { focused.wrappedValue || !draft.isEmpty || busy }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if expanded, let options {
                Button(action: { hapticTap(); options() }) {
                    Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                        .frame(width: 36, height: 36).background(Theme.surfaceHigh, in: Circle())
                        .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.pressable).foregroundStyle(Theme.text)
                .accessibilityLabel("选项").accessibilityIdentifier("composerOptionsButton")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused(focused)
                .font(.body)
                .padding(.leading, expanded && options != nil ? 2 : 18).padding(.vertical, expanded ? 13 : 12)
                .accessibilityIdentifier("composerField")
            if expanded {
                Button(action: showsStop ? stop : send) {
                    ZStack {
                        Circle().fill(showsStop ? Theme.buttonFill : (hasText ? Theme.buttonFill : Theme.surfaceHigh)).frame(width: 36, height: 36)
                        Image(systemName: showsStop ? "stop.fill" : "arrow.up").font(.system(size: showsStop ? 13 : 16, weight: .bold))
                            .foregroundStyle(showsStop || hasText ? Theme.buttonText : Theme.textSecondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(width: 44, height: 44)   // 视觉 36pt，点击区域 44pt
                    .contentShape(Circle())
                }
                .buttonStyle(.pressable)
                .disabled(!showsStop && !hasText)
                .animation(.easeOut(duration: 0.15), value: showsStop)
                .accessibilityLabel(showsStop ? "停止" : "发送")
                .accessibilityIdentifier(showsStop ? "stopButton" : "sendButton")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.trailing, expanded ? 4 : 18)
        .padding(.leading, expanded && options != nil ? 4 : 0)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: expanded ? 26 : 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: expanded ? 26 : 24, style: .continuous).stroke(Theme.separator, lineWidth: 1))
        .padding(.horizontal, expanded ? 12 : 32).padding(.top, 6).padding(.bottom, 8)
        .background(Theme.background)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: expanded)
    }
}

/// 输入栏“+”：当前 Bot 的模型、思考等级、权限，改了立即生效（和 Bot 设置里是同一份数据）。
struct ComposerOptionsSheet: View {
    @Environment(TeamStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let botId: String
    @State private var error: String?

    private var bot: Bot? { store.bots.first { $0.id == botId } }
    private var modelRef: String { (bot?.model.isEmpty ?? true) ? store.defaultModel : (bot?.model ?? "") }
    private var currentModel: ModelOption? { store.models.first { $0.ref == modelRef } }
    private var permission: String { bot?.permission ?? store.defaultPermission }

    var body: some View {
        NavigationStack {
            List {
                Section("模型") {
                    ForEach(store.models) { option in
                        Button {
                            var patch: [String: Any] = ["model": option.ref]
                            if let bot, !option.efforts.contains(bot.effort) {
                                patch["effort"] = option.efforts.contains("high") ? "high" : (option.efforts.first ?? "")
                            }
                            apply(patch)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.name)
                                    if !option.provider.isEmpty { Text(option.provider).font(.caption).foregroundStyle(Theme.textSecondary) }
                                }
                                Spacer()
                                if option.ref == modelRef { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(Theme.text)
                    }
                }
                if let efforts = currentModel?.efforts, !efforts.isEmpty {
                    Section("思考等级") {
                        Picker("思考等级", selection: Binding(get: { bot?.effort ?? "" }, set: { apply(["effort": $0]) })) {
                            ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("权限") {
                    ForEach(store.permissionOptions) { option in
                        Button { apply(["permission": option.value]) } label: {
                            HStack {
                                Text(option.label)
                                Spacer()
                                if option.value == permission { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(Theme.text)
                    }
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle("\(bot?.name ?? "") 的选项").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func apply(_ patch: [String: Any]) {
        hapticTap()
        error = nil
        Task {
            do { try await store.updateBot(botId, patch) } catch { self.error = error.localizedDescription }
        }
    }
}

/// 需要你处理的审批 / 提问固定在输入栏上方，不随历史消息滚走（和网页端一致）。
/// 内容很长时自身可滚动，最多占屏幕约 45%，不会把输入栏挤出去。
private struct InteractionDock: View {
    let approvals: [Approval]
    let question: Question?
    /// 用户点“×”收起的提问（只在本次打开里有效）；收起后留一行入口，不会丢
    @State private var dismissed: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(approvals) { ApprovalCard(approval: $0) }
                if let question {
                    if dismissed.contains(question.id) {
                        Button { withAnimation(.easeOut(duration: 0.2)) { _ = dismissed.remove(question.id) } } label: {
                            HStack {
                                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Theme.accent)
                                Text("Bot 在等你回答").font(.system(size: 14, weight: .medium))
                                Spacer()
                                Text("展开").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Theme.surface, in: Capsule())
                        }
                        .buttonStyle(.pressable).foregroundStyle(Theme.text)
                        .accessibilityIdentifier("questionCollapsed")
                    } else {
                        QuestionCard(question: question) { withAnimation(.easeOut(duration: 0.2)) { _ = dismissed.insert(question.id) } }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 6)
        }
        .frame(maxHeight: UIScreen.main.bounds.height * 0.45)
        .fixedSize(horizontal: false, vertical: true)
        .scrollBounceBehavior(.basedOnSize)
    }
}

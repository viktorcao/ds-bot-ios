import SwiftUI

struct RootView: View {
    @Environment(TeamStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        Group {
            switch store.phase {
            case .needsLogin: LoginView()
            case .connecting where store.bots.isEmpty: ConnectingView()
            default: main
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .onChange(of: scenePhase) { _, phase in
            // 进后台后由 store 借约 30 秒继续轮询，到时间才停；下拉通知中心（inactive）不受影响
            if phase == .active { store.didBecomeActive() } else if phase == .background { store.didEnterBackground() }
        }
    }

    private var push: Animation { .spring(response: 0.34, dampingFraction: 0.92) }

    private func back() {
        dismissKeyboard()
        withAnimation(push) { store.closeChat() }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var main: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let open = store.chatOpen && store.selectedBot != nil
            let offset = open ? max(0, drag) : width
            ZStack(alignment: .leading) {
                Group {
                    if store.bots.isEmpty, let message = store.offlineMessage {
                        OfflineView(message: message) { store.retryNow() }
                    } else {
                        BotListView()
                    }
                }
                .frame(width: width)
                .offset(x: reduceMotion ? 0 : -(1 - min(1, offset / width)) * 80 * (open ? 1 : 0))
                .opacity(open && offset < 1 ? 0.6 : 1)
                .accessibilityHidden(open)

                if open, let bot = store.selectedBot {
                    ChatView(bot: bot, back: back)
                        .frame(width: width)
                        .background(Theme.background)
                        // 阴影只在推入或拖动时有：整页常驻阴影会让滚动每帧都离屏渲染
                        .shadow(color: .black.opacity(offset > 0.5 ? 0.3 : 0), radius: offset > 0.5 ? 14 : 0)
                        .offset(x: offset)
                        .transition(.move(edge: .trailing))
                        .zIndex(1)
                        .gesture(
                            // 只认从左边缘开始的横滑，避免和聊天里的滚动、选字冲突
                            DragGesture(minimumDistance: 14)
                                .updating($drag) { value, state, _ in
                                    if value.startLocation.x < 28, value.translation.width > 0, abs(value.translation.width) > abs(value.translation.height) { state = value.translation.width }
                                }
                                .onEnded { value in
                                    guard value.startLocation.x < 28, abs(value.translation.width) > abs(value.translation.height) else { return }
                                    if value.translation.width > width / 3 || value.predictedEndTranslation.width > width / 2 { back() }
                                }
                        )
                        .accessibilityAction(.escape) { back() }
                }
            }
            .animation(push, value: open)
            .overlay(alignment: .top) {
                VStack(spacing: 6) {
                    // 离线是状态，不是一次性消息：聊天页里也常驻小标（列表页自己的顶栏里有）
                    if open && store.offlineMessage != nil {
                        Label("离线 · 正在重连", systemImage: "wifi.slash").font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    if let message = store.banner {
                        Text(message).font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .onTapGesture { store.banner = nil }
                            .task(id: message) {
                                UIAccessibility.post(notification: .announcement, argument: message)
                                try? await Task.sleep(for: .seconds(5)); if store.banner == message { store.banner = nil }
                            }
                    }
                }
                .padding(.top, 4).transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeOut(duration: 0.2), value: store.banner)
                .animation(.easeOut(duration: 0.2), value: store.offlineMessage == nil)
            }
        }
    }
}

/// 还没拿到任何数据就连不上：给出原因和重试，而不是一直转圈或踢回登录页
private struct OfflineView: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.slash").font(.system(size: 34)).foregroundStyle(Theme.textSecondary)
            Text("连不上服务器").font(.headline)
            Text(message).font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            Button("重试") { retry() }
                .buttonStyle(.borderedProminent).tint(Theme.buttonFill).foregroundStyle(Theme.buttonText)
            Text("会在后台自动重试").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("offlineView")
    }
}

private struct ConnectingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("正在连接…").font(.footnote).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

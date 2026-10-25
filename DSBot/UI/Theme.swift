import SwiftUI
import UIKit

/// 参照 Grok iOS 的视觉：纯黑底、低对比灰色层级、白色主按钮、大圆角。浅色模式自动反转。
enum Theme {
    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let background = dynamic(dark: 0x000000, light: 0xFFFFFF)
    static let surface = dynamic(dark: 0x151517, light: 0xF4F4F6)
    static let surfaceHigh = dynamic(dark: 0x242427, light: 0xE9E9EC)
    static let separator = dynamic(dark: 0x2A2A2E, light: 0xDEDEE2)
    static let text = dynamic(dark: 0xF2F2F4, light: 0x111113)
    static let textSecondary = dynamic(dark: 0x8E8E93, light: 0x6C6C70)
    static let buttonFill = dynamic(dark: 0xFFFFFF, light: 0x000000)
    static let buttonText = dynamic(dark: 0x000000, light: 0xFFFFFF)
    static let accent = Color(red: 0.30, green: 0.42, blue: 1.0)   // DeepSeek 蓝
    static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)
}

/// 与网页端同一套头像：自定义图片优先，否则按“形状 + 颜色”画角色。主 Bot 在侧栏带一颗星标。
struct AvatarView: View {
    let bot: Bot
    var size: CGFloat = 36
    var isMain = false
    var badge = false

    var body: some View {
        Group {
            if let image = Self.image(from: bot.avatarImage) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size).clipShape(Circle())
            } else {
                CharacterView(shape: bot.shape, color: bot.color)
                    .frame(width: size, height: size)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if badge && isMain {
                Image(systemName: "star.fill").font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: "#FFC233"), Color(hex: "#FF8A00")], startPoint: .top, endPoint: .bottom))
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
    }

    private static func image(from dataURL: String?) -> UIImage? {
        guard let dataURL, let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return UIImage(data: data)
    }
}

extension View {
    func hapticTap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}


/// 按压反馈：轻微缩小 + 变暗，松手弹回。所有可点的自定义按钮都应使用，系统默认按钮没有按下态。
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // 自定义 ButtonStyle 下透明区域（Spacer、留白）默认不响应点击，必须显式声明整块可点
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

/// 常驻活动指示：同一时刻页面上只允许一个连续动画。只改变不透明度，系统开启“减少动态效果”时静止在中间值。
struct LivenessDot: View {
    var color: Color = Theme.accent
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .opacity(reduceMotion ? 0.7 : (on ? 1 : 0.3))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// 把秒数写成 "7s" / "1m 12s"
func elapsedText(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
}

import SwiftUI
import UIKit

/// DS Bot 网页端的头像是一张“角色表”：每个角色由几条折线路径（只有 M / l / z，相对坐标）加两个挖空的眼睛组成，
/// 100×100 视口。表从网页端导出为 `Avatars.json`，这里按相同的图层顺序画出来，因此和网页端完全一致。
struct CharacterDef: Decodable {
    let label: String
    let body: String
    let paints: [Paint]
    let shade: String
    let light: String
    let eyes: [[Double]]   // [cx, cy, 宽, 高, 旋转角度]

    struct Paint: Decodable {
        let path: String
        let fill: String
        let opacity: Double
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            path = try c.decode(String.self)
            fill = try c.decode(String.self)
            opacity = try c.decode(Double.self)
        }
    }
}

enum CharacterArt {
    struct Table: Decodable {
        let characters: [String: CharacterDef]
        let inks: [String: [String]]
        let gradients: [String: [[JSONValue]]]
    }

    static let table: Table = {
        guard let url = Bundle.main.url(forResource: "Avatars", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(Table.self, from: data) else {
            return Table(characters: [:], inks: [:], gradients: [:])
        }
        return table
    }()

    /// 网页端“选形状”面板的顺序
    static let shapeIds = ["whale", "star", "moon", "wave", "squircle", "zed", "hex", "gumdrop", "peanut", "saucer",
                           "bunny", "kitty", "beacon", "plus", "magnet", "acorn", "pebbles", "cushion", "ring", "gem"]
    static let colorIds = ["deepseek", "charcoal", "graphite", "rose", "sky", "tangerine", "cobalt",
                           "black", "brown", "red", "orange", "yellow", "green", "cyan", "blue", "violet", "magenta", "gray", "aurora"]

    // MARK: 默认形状 / 颜色（移植网页端：没设置头像的 Bot 按 id 哈希取值，保证两端一致）
    private static func fnv1a(_ text: String) -> UInt32 {
        var value: UInt32 = 2166136261
        for unit in text.utf16 { value = (value ^ UInt32(unit)) &* 16777619 }
        return value
    }

    static func defaultShape(_ id: String) -> String {
        let shapes = ["star", "moon", "gumdrop", "peanut", "bunny", "kitty", "acorn"]
        var v = Int32(bitPattern: fnv1a(id))
        v = (v ^ Int32(bitPattern: UInt32(bitPattern: v) >> 16)) &* 73244475
        v = (v ^ Int32(bitPattern: UInt32(bitPattern: v) >> 13)) &* Int32(bitPattern: 3266489909)
        let mixed = UInt32(bitPattern: v ^ Int32(bitPattern: UInt32(bitPattern: v) >> 16))
        return shapes[Int(mixed % UInt32(shapes.count))]
    }

    static func defaultColor(_ id: String) -> String {
        let colors = ["red", "orange", "yellow", "green", "cyan", "blue", "violet", "magenta"]
        let t2 = Int32(bitPattern: fnv1a(id) &+ 1831565813)
        var n = (t2 ^ Int32(bitPattern: UInt32(bitPattern: t2) >> 15)) &* (1 | t2)
        n = (n &+ ((n ^ Int32(bitPattern: UInt32(bitPattern: n) >> 7)) &* (61 | n))) ^ n
        let mixed = UInt32(bitPattern: n ^ Int32(bitPattern: UInt32(bitPattern: n) >> 14))
        return colors[Int(Double(mixed) / 4294967296.0 * Double(colors.count))]
    }

    static func isHex(_ text: String) -> Bool { text.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil }

    static func color(_ name: String, dark: Bool) -> Color {
        if isHex(name) { return Color(hex: name) }
        if let pair = table.inks[name], !pair.isEmpty { return Color(hex: pair[dark && pair.count > 1 ? 1 : 0]) }
        return .gray
    }

    // MARK: 路径：只支持 M / l / z（角色表实际只用到这三个）
    static func path(from d: String) -> Path {
        var path = Path()
        var scanner = Array(d)
        var i = 0
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command: Character = "M"

        func number() -> Double? {
            while i < scanner.count, scanner[i] == " " || scanner[i] == "," { i += 1 }
            guard i < scanner.count else { return nil }
            var text = ""
            if scanner[i] == "-" { text.append("-"); i += 1 }
            var seenDot = false
            while i < scanner.count {
                let c = scanner[i]
                if c.isNumber { text.append(c); i += 1 }
                else if c == ".", !seenDot { seenDot = true; text.append(c); i += 1 }
                else { break }
            }
            return Double(text)
        }

        while i < scanner.count {
            let c = scanner[i]
            if c == " " || c == "," { i += 1; continue }
            if c == "M" || c == "l" || c == "z" || c == "Z" { command = c; i += 1
                if c == "z" || c == "Z" { path.closeSubpath(); current = start; continue }
            }
            guard let x = number(), let y = number() else { break }
            switch command {
            case "M":
                current = CGPoint(x: x, y: y); start = current; path.move(to: current); command = "L"   // 后续坐标对按绝对 lineTo
            case "L":
                current = CGPoint(x: x, y: y); path.addLine(to: current)
            default: // "l"
                current = CGPoint(x: current.x + x, y: current.y + y); path.addLine(to: current)
            }
        }
        scanner.removeAll()
        return path
    }
}

extension Color {
    init(hex: String) {
        var text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        let value = UInt32(text, radix: 16) ?? 0x808080
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// 画一个角色：本体 → 色块 → 暗部 → 高光 → 挖出眼睛。
struct CharacterView: View {
    let shape: String
    let color: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let table = CharacterArt.table
        let def = table.characters[shape] ?? table.characters["gumdrop"]
        Canvas { context, size in
            guard let def else { return }
            let scale = min(size.width, size.height) / 100
            let dx = (size.width - 100 * scale) / 2, dy = (size.height - 100 * scale) / 2
            let transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
            context.drawLayer { layer in
                let ink = CharacterArt.color(color, dark: scheme == .dark)
                let body = CharacterArt.path(from: def.body).applying(transform)
                if color == "aurora", let stops = table.gradients["aurora"] {
                    let gradient = Gradient(stops: stops.map { .init(color: Color(hex: $0[1].string ?? "#00F0E4"), location: $0[0].double ?? 0) })
                    layer.fill(body, with: .linearGradient(gradient, startPoint: CGPoint(x: dx, y: dy), endPoint: CGPoint(x: dx + 100 * scale, y: dy + 100 * scale)), style: FillStyle(eoFill: true))
                } else {
                    layer.fill(body, with: .color(ink), style: FillStyle(eoFill: true))
                }
                for paint in def.paints {
                    layer.fill(CharacterArt.path(from: paint.path).applying(transform), with: .color(Color(hex: paint.fill).opacity(paint.opacity)), style: FillStyle(eoFill: true))
                }
                if !def.shade.isEmpty { layer.fill(CharacterArt.path(from: def.shade).applying(transform), with: .color(.black.opacity(0.14)), style: FillStyle(eoFill: true)) }
                if !def.light.isEmpty { layer.fill(CharacterArt.path(from: def.light).applying(transform), with: .color(.white.opacity(0.16)), style: FillStyle(eoFill: true)) }
                layer.blendMode = .destinationOut
                for eye in def.eyes where eye.count >= 5 {
                    let rect = CGRect(x: -eye[2] / 2, y: -eye[3] / 2, width: eye[2], height: eye[3])
                    var path = Path(roundedRect: rect, cornerRadius: eye[2] / 2)
                    path = path.applying(CGAffineTransform(rotationAngle: eye[4] * .pi / 180).translatedBy(x: 0, y: 0))
                    path = path.applying(CGAffineTransform(translationX: eye[0], y: eye[1]))
                    layer.fill(path.applying(transform), with: .color(.black))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

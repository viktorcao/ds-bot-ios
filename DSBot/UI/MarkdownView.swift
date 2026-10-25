import SwiftUI
import UIKit

/// 轻量 Markdown 渲染：代码块、标题、列表、引用，行内粗体/斜体/链接/行内代码交给系统解析。
struct MarkdownView: View {
    let text: String

    private enum Block: Identifiable {
        case paragraph(String)
        case heading(String, Int)
        case bullet(String, Int)
        case numbered(String, String)
        case quote(String)
        case code(String, String)
        case table([[String]])
        var id: String {
            switch self {
            case .paragraph(let s): return "p\(s.hashValue)"
            case .heading(let s, let l): return "h\(l)\(s.hashValue)"
            case .bullet(let s, let i): return "b\(i)\(s.hashValue)"
            case .numbered(let n, let s): return "n\(n)\(s.hashValue)"
            case .quote(let s): return "q\(s.hashValue)"
            case .code(let s, let l): return "c\(l)\(s.hashValue)"
            case .table(let rows): return "t\(rows.hashValue)"
            }
        }
    }

    /// 解析结果按文本缓存：聊天页每次重绘（轮询、滚动、键盘）都会重建视图，但文本没变就不必重新解析
    private final class Parsed { let blocks: [Block]; init(_ blocks: [Block]) { self.blocks = blocks } }
    private static let cache: NSCache<NSString, Parsed> = { let c = NSCache<NSString, Parsed>(); c.countLimit = 400; return c }()

    private var blocks: [Block] {
        if let hit = Self.cache.object(forKey: text as NSString) { return hit.blocks }
        let parsed = parse()
        Self.cache.setObject(Parsed(parsed), forKey: text as NSString)
        return parsed
    }

    private func parse() -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var language = ""
        var inCode = false
        var table: [String] = []
        func flushTable() {
            guard !table.isEmpty else { return }
            // 至少表头 + 分隔行；分隔行（|---|---|）不显示
            let rows = table.filter { !$0.contains("---") || $0.contains(where: { $0.isLetter || $0.isNumber }) }
                .map { line -> [String] in
                    var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    if cells.first == "" { cells.removeFirst() }
                    if cells.last == "" { cells.removeLast() }
                    return cells
                }
            if table.count >= 2 { result.append(.table(rows)) } else { result.append(.paragraph(table.joined(separator: "\n"))) }
            table = []
        }
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode { result.append(.code(code.joined(separator: "\n"), language)); code = []; inCode = false }
                else { flush(); inCode = true; language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                continue
            }
            if inCode { code.append(line); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { flush(); table.append(trimmed); continue }
            flushTable()
            if trimmed.isEmpty { flush(); continue }
            if let match = trimmed.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flush()
                let level = trimmed[match].dropLast().count
                result.append(.heading(String(trimmed[match.upperBound...]), level))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flush()
                let indent = line.prefix { $0 == " " }.count / 2
                result.append(.bullet(String(trimmed.dropFirst(2)), indent))
            } else if let match = trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flush()
                result.append(.numbered(String(trimmed[..<match.upperBound]).trimmingCharacters(in: .whitespaces), String(trimmed[match.upperBound...])))
            } else if trimmed.hasPrefix("> ") {
                flush()
                result.append(.quote(String(trimmed.dropFirst(2))))
            } else {
                paragraph.append(trimmed)
            }
        }
        if inCode { result.append(.code(code.joined(separator: "\n"), language)) }
        flush()
        flushTable()
        return result
    }

    private func inline(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: source, options: options) { return Text(attributed) }
        return Text(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block {
                case .paragraph(let s):
                    inline(s).fixedSize(horizontal: false, vertical: true)
                case .heading(let s, let level):
                    inline(s).font(.system(size: level <= 1 ? 22 : level == 2 ? 19 : 17, weight: .bold))
                        .padding(.top, 4)
                case .bullet(let s, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.textSecondary)
                        inline(s).fixedSize(horizontal: false, vertical: true)
                    }.padding(.leading, CGFloat(indent) * 14)
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(n).foregroundStyle(Theme.textSecondary).monospacedDigit()
                        inline(s).fixedSize(horizontal: false, vertical: true)
                    }
                case .quote(let s):
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Theme.separator).frame(width: 3)
                        inline(s).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                case .code(let s, let language):
                    CodeBlock(code: s, language: language)
                case .table(let rows):
                    TableBlock(rows: rows) { inline($0) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(Theme.accent)   // 链接颜色
    }
}

/// 表格：整体可以横向滚动；表头加粗，行与行之间有分隔线
private struct TableBlock: View {
    let rows: [[String]]
    let cell: (String) -> Text

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, text in
                            cell(text).fontWeight(index == 0 ? .semibold : .regular)
                                .frame(width: 150, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 9)
                    if index < rows.count - 1 { Divider().overlay(Theme.separator) }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct CodeBlock: View {
    let code: String
    let language: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().overlay(Theme.separator)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    .padding(12).fixedSize(horizontal: true, vertical: false)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.separator, lineWidth: 1))
    }
}

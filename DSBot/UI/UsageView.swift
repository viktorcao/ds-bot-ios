import SwiftUI
import Charts

/// 用量：按时间范围汇总 Token，按 Bot 或按模型堆叠显示走势。数据来自 `usage` 端点的小时级记录。
struct UsageView: View {
    @Environment(TeamStore.self) private var store
    @State private var report = UsageReport()
    @State private var loading = true
    @State private var error: String?
    @State private var range: Range = .week
    @State private var group: Group = .bot
    @State private var customFrom = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
    @State private var customTo = Date()

    enum Range: String, CaseIterable, Identifiable {
        case day = "24 小时", week = "7 天", month = "30 天", weeks12 = "12 周", months12 = "12 个月", custom = "自定义"
        var id: String { rawValue }
    }
    enum Group: String, CaseIterable, Identifiable { case bot = "按 Bot", model = "按模型"; var id: String { rawValue } }

    private struct Bucket: Identifiable { let id: String; let start: Date; let series: String; let value: Int }

    private static let hourFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private var calendar: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c }

    private var interval: (from: Date, to: Date, unit: Calendar.Component) {
        let end = Self.hourFormat.date(from: report.now).map { $0.addingTimeInterval(3600) } ?? Date()
        switch range {
        case .day: return (end.addingTimeInterval(-24 * 3600), end, .hour)
        case .week: return (calendar.date(byAdding: .day, value: -7, to: end) ?? end, end, .day)
        case .month: return (calendar.date(byAdding: .day, value: -30, to: end) ?? end, end, .day)
        case .weeks12: return (calendar.date(byAdding: .weekOfYear, value: -12, to: end) ?? end, end, .weekOfYear)
        case .months12: return (calendar.date(byAdding: .month, value: -12, to: end) ?? end, end, .month)
        case .custom:
            let days = calendar.dateComponents([.day], from: customFrom, to: customTo).day ?? 0
            return (calendar.startOfDay(for: customFrom), calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customTo)) ?? customTo, days > 120 ? .month : days > 60 ? .weekOfYear : .day)
        }
    }

    private var rowsInRange: [(row: UsageRow, date: Date)] {
        let (from, to, _) = interval
        return report.rows.compactMap { row in
            guard let date = Self.hourFormat.date(from: row.hour), date >= from, date < to else { return nil }
            return (row, date)
        }
    }

    private func seriesName(_ row: UsageRow) -> String {
        switch group {
        case .bot: return report.owners.indices.contains(row.owner) ? (report.owners[row.owner].kind == "other" ? "其他" : report.owners[row.owner].name) : "其他"
        case .model: return report.models.indices.contains(row.model) ? report.models[row.model] : "其他"
        }
    }

    private var buckets: [Bucket] {
        let unit = interval.unit
        var sums: [String: Int] = [:]
        var starts: [String: Date] = [:]
        for (row, date) in rowsInRange {
            let start = calendar.dateInterval(of: unit, for: date)?.start ?? date
            let series = seriesName(row)
            let key = "\(start.timeIntervalSince1970)|\(series)"
            sums[key, default: 0] += row.total
            starts[key] = start
        }
        return sums.map { key, value in
            Bucket(id: key, start: starts[key] ?? Date(), series: String(key.split(separator: "|", maxSplits: 1)[1]), value: value)
        }.sorted { $0.start < $1.start }
    }

    private var seriesNames: [String] {
        var totals: [String: Int] = [:]
        for (row, _) in rowsInRange { totals[seriesName(row), default: 0] += row.total }
        return totals.sorted { $0.value > $1.value }.map(\.key)
    }

    private func color(for name: String, index: Int) -> Color {
        if group == .bot {
            if name == "其他" { return Color.gray.opacity(0.6) }
            if let bot = store.bots.first(where: { $0.name == name }) { return CharacterArt.color(bot.color, dark: true) }
            return Color.gray
        }
        let palette: [Color] = [Theme.accent, .orange, .green, .pink, .teal, .purple, .yellow]
        return palette[index % palette.count]
    }

    private var totals: (all: Int, cacheRate: Double, output: Int, calls: Int) {
        var all = 0, cache = 0, input = 0, output = 0, calls = 0
        for (row, _) in rowsInRange {
            all += row.total; cache += row.cacheRead; input += row.input + row.cacheRead + row.cacheWrite; output += row.output; calls += row.calls
        }
        return (all, input == 0 ? 0 : Double(cache) / Double(input), output, calls)
    }

    private func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        case 1_000...: return String(format: "%.0fK", Double(value) / 1_000)
        default: return "\(value)"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Range.allCases) { item in
                            Button { range = item } label: {
                                Text(item.rawValue).font(.system(size: 14, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(range == item ? Theme.surfaceHigh : .clear, in: Capsule())
                                    .overlay(Capsule().stroke(range == item ? Theme.separator : .clear, lineWidth: 1))
                            }.foregroundStyle(range == item ? Theme.text : Theme.textSecondary)
                        }
                    }
                    .padding(4).background(Theme.surface, in: Capsule())
                }
                if range == .custom {
                    HStack {
                        DatePicker("", selection: $customFrom, in: ...customTo, displayedComponents: .date).labelsHidden()
                        Text("–").foregroundStyle(Theme.textSecondary)
                        DatePicker("", selection: $customTo, in: customFrom..., displayedComponents: .date).labelsHidden()
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                else if let error { Text(error).foregroundStyle(Theme.danger) }
                else { content }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("用量").navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private var content: some View {
        let t = totals
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近 \(range.rawValue)").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(compact(t.all)).font(.system(size: 34, weight: .bold)); Text("Token").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            Divider().overlay(Theme.separator)
            HStack(spacing: 0) {
                stat("缓存命中率", "\(Int((t.cacheRate * 100).rounded()))%")
                Divider().overlay(Theme.separator)
                stat("输出", compact(t.output))
                Divider().overlay(Theme.separator)
                stat("调用次数", "\(t.calls)")
            }.frame(height: 76)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.separator, lineWidth: 1))

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Token 走势").font(.system(size: 16, weight: .bold))
                Text(interval.unit == .hour ? "按小时" : interval.unit == .day ? "按天" : interval.unit == .weekOfYear ? "按周" : "按月").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("", selection: $group) { ForEach(Group.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 170)
            }
            let names = seriesNames
            Chart(buckets) { bucket in
                BarMark(x: .value("时间", bucket.start, unit: interval.unit), y: .value("Token", bucket.value))
                    .foregroundStyle(by: .value("系列", bucket.series))
            }
            .chartForegroundStyleScale(domain: names, range: names.enumerated().map { color(for: $0.element, index: $0.offset) })
            .chartLegend(.hidden)
            .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Int.self) { Text(compact(n)).font(.system(size: 10)) } } } }
            .frame(height: 220)
            FlowLegend(names: names) { name, index in color(for: name, index: index) }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.separator, lineWidth: 1))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(size: 22, weight: .bold))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
    }

    private func load() async {
        do { report = try await store.usage(); error = nil } catch { self.error = error.localizedDescription }
        loading = false
    }
}

/// 图例：圆点 + 名称，自动换行。
private struct FlowLegend: View {
    let names: [String]
    let color: (String, Int) -> Color
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 6) {
                    Circle().fill(color(name, index)).frame(width: 9, height: 9)
                    Text(name).font(.system(size: 13)).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.surfaceHigh, in: Capsule())
            }
        }
    }
}

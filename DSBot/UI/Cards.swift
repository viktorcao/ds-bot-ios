import SwiftUI

/// 工具调用审批：要做什么 / 命令 / 凭什么，然后是两个够大的按钮。阻塞的是这个 Bot，不是整个页面。
struct ApprovalCard: View {
    @Environment(TeamStore.self) private var store
    let approval: Approval
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                Text("需要你的批准").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Spacer()
                Text(approval.tool).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.surfaceHigh, in: Capsule())
            }
            Text(approval.title.isEmpty ? approval.reason : approval.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            if !approval.detail.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(approval.detail).font(.system(size: 13, design: .monospaced)).lineLimit(4).padding(12).textSelection(.enabled)
                }
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 12))
            }
            if !approval.title.isEmpty && !approval.reason.isEmpty {
                Label { Text(approval.reason).font(.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "questionmark.circle").foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(spacing: 10) {
                Button { hapticTap(.medium); Task { await store.answer(approval, allow: false) } } label: {
                    Text("拒绝").frame(maxWidth: .infinity).frame(height: 48)
                        .background(Theme.surfaceHigh, in: Capsule())
                }
                .buttonStyle(.pressable).foregroundStyle(Theme.text).accessibilityIdentifier("rejectButton")
                Button { hapticTap(.medium); Task { await store.answer(approval, allow: true) } } label: {
                    Text("允许一次").frame(maxWidth: .infinity).frame(height: 48)
                        .background(Theme.buttonFill, in: Capsule())
                }
                .buttonStyle(.pressable).foregroundStyle(Theme.buttonText).accessibilityIdentifier("approveButton")
                // 次要操作收进“更多”，不和主操作抢位置
                Menu {
                    Button { showDetails = true } label: { Label("查看完整详情", systemImage: "text.alignleft") }
                    Button { UIPasteboard.general.string = approval.detail.isEmpty ? approval.title : approval.detail } label: { Label("复制命令", systemImage: "doc.on.doc") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                        .frame(width: 48, height: 48).background(Theme.surfaceHigh, in: Circle())
                }
                .foregroundStyle(Theme.text).accessibilityLabel("更多").accessibilityIdentifier("approvalMoreButton")
            }
            .font(.system(size: 16, weight: .semibold))
            .disabled(!store.canAnswer(approval))
            .opacity(store.canAnswer(approval) ? 1 : 0.5)
            if !store.canAnswer(approval) {
                Text("正在同步审批请求…").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.orange.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approvalCard")
        .sheet(isPresented: $showDetails) { ApprovalDetailsSheet(approval: approval) }
    }
}

private struct ApprovalDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let approval: Approval

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("工具") { Text(approval.tool).font(.system(.body, design: .monospaced)) }
                    if !approval.title.isEmpty { Text(approval.title).font(.headline) }
                    if !approval.reason.isEmpty { Text(approval.reason).font(.subheadline).foregroundStyle(Theme.textSecondary) }
                    if !approval.detail.isEmpty {
                        Text(approval.detail).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(16)
            }
            .navigationTitle("审批详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Bot 用 ask_user 向你提问：选项或自由回答。
struct QuestionCard: View {
    @Environment(TeamStore.self) private var store
    let question: Question
    var collapse: (() -> Void)? = nil
    @State private var selected: Set<String> = []
    @State private var custom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Bot 想问你", systemImage: "questionmark.bubble.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                Spacer()
                if let collapse {
                    Button(action: collapse) { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 44, height: 32, alignment: .trailing) }
                        .foregroundStyle(Theme.textSecondary).accessibilityLabel("先收起").accessibilityIdentifier("questionCollapse")
                }
            }
            Text(question.text).font(.system(size: 16, weight: .medium))
            if !question.detail.isEmpty { Text(question.detail).font(.system(size: 14)).foregroundStyle(Theme.textSecondary) }
            ForEach(question.options, id: \.label) { option in
                Button {
                    hapticTap()
                    if question.multiSelect {
                        if selected.contains(option.label) { selected.remove(option.label) } else { selected.insert(option.label) }
                    } else {
                        Task { await store.answer(question, selected: [option.label]) }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).font(.system(size: 15, weight: .medium))
                            if !option.description.isEmpty { Text(option.description).font(.system(size: 13)).foregroundStyle(Theme.textSecondary) }
                        }
                        Spacer()
                        if question.multiSelect { Image(systemName: selected.contains(option.label) ? "checkmark.circle.fill" : "circle") }
                    }
                    .padding(12).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.pressable).foregroundStyle(Theme.text).accessibilityIdentifier("option-\(option.label)")
            }
            HStack {
                TextField("或者自己回答…", text: $custom, axis: .vertical).lineLimit(1...3)
                Button {
                    Task { await store.answer(question, selected: Array(selected), custom: custom) }
                } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)) }
                .disabled(selected.isEmpty && custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.accent.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("questionCard")
    }
}

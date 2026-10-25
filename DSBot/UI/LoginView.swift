import SwiftUI

struct LoginView: View {
    @Environment(TeamStore.self) private var store
    @State private var url = ""
    @State private var user = ""
    @State private var password = ""
    @FocusState private var field: Field?
    private enum Field { case url, user, password }

    private var connecting: Bool { store.phase == .connecting }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 56)
                Image("Logo")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).stroke(Theme.separator, lineWidth: 1))
                Text("DS Bot").font(.system(size: 30, weight: .bold))
                Text("连接到你的 Bot 团队").font(.system(size: 15)).foregroundStyle(Theme.textSecondary)

                VStack(spacing: 12) {
                    input("服务器地址，例如 bot.example.com:81", text: $url, icon: "link", field: .url, keyboard: .URL)
                    input("用户名（可选）", text: $user, icon: "person", field: .user)
                    input("密码（可选）", text: $password, icon: "lock", field: .password, secure: true)
                }
                .padding(.top, 8)

                if let error = store.loginError {
                    Text(error).font(.system(size: 14)).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
                }

                Button {
                    field = nil
                    Task { await store.login(ServerConfig(url: url, user: user, password: password)) }
                } label: {
                    HStack {
                        if connecting { ProgressView().tint(Theme.buttonText) }
                        Text(connecting ? "连接中…" : "连接").font(.system(size: 17, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(Theme.buttonFill, in: Capsule())
                    .foregroundStyle(Theme.buttonText)
                }
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || connecting)
                .opacity(url.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)

                Text("密码只保存在这台 iPhone 的钥匙串里。").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .onAppear {
            url = store.config.url
            user = store.config.user
            password = store.config.password
        }
    }

    @ViewBuilder
    private func input(_ placeholder: String, text: Binding<String>, icon: String, field: Field, keyboard: UIKeyboardType = .default, secure: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.textSecondary).frame(width: 20)
            Group {
                if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
            }
            .focused($field, equals: field)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.separator, lineWidth: 1))
    }
}

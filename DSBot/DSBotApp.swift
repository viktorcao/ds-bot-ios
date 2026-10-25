import SwiftUI

@main
struct DSBotApp: App {
    @State private var store = TeamStore()
    @AppStorage("dsbot.appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
    }
}

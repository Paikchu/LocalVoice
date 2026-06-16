import SwiftUI

@main
struct LocalVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: appDelegate.model)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundStyle(.primary)
                .accessibilityLabel("LocalVoice")
        }
        .menuBarExtraStyle(.window)
    }
}

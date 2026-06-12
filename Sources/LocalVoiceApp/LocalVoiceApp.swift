import SwiftUI

@main
struct LocalVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: appDelegate.model)
        } label: {
            Image(systemName: appDelegate.model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

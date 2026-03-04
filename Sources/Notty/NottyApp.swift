import SwiftUI

@main
struct NottyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            Text("Notty Settings")
        }
    }
}

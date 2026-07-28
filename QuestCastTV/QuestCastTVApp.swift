import SwiftUI

@main
struct QuestCastTVApp: App {
    @StateObject private var receiver = ReceiverController()

    var body: some Scene {
        WindowGroup {
            ContentView(receiver: receiver)
        }
    }
}


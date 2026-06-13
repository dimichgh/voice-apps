import SwiftUI

@main
struct VoiceChatApp: App {
    @StateObject private var session = ChatSession()

    var body: some Scene {
        WindowGroup("VoiceChat") {
            ContentView(session: session, voiceCatalog: session.voiceCatalog)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowStyle(.titleBar)
    }
}

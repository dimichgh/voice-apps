import SwiftUI

@main
struct VoiceDubApp: App {
    @StateObject private var app = AppModel()
    @StateObject private var catalog = VoiceCatalog()

    var body: some Scene {
        WindowGroup("VoiceDub") {
            ContentView(catalog: catalog)
                .environmentObject(app)
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowStyle(.titleBar)
    }
}

import SwiftUI

struct ContentView: View {
    @ObservedObject var catalog: VoiceCatalog

    var body: some View {
        TabView {
            VoiceLibraryView(catalog: catalog)
                .tabItem { Label("Voices", systemImage: "person.wave.2") }
            DubView(catalog: catalog)
                .tabItem { Label("Dub Video", systemImage: "film") }
        }
        .padding(8)
    }
}

import SwiftUI

@main
struct CarPlayLyricsApp: App {
    @StateObject private var observer = MusicObserver()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(observer)
                .preferredColorScheme(.dark)
                .onAppear { observer.appBecameActive() }
        }
    }
}

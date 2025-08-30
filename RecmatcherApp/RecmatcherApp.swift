
import SwiftUI

@main
struct RecmatcherApp: App {
    @StateObject private var store = AppStore()
    var body: some SwiftUI.Scene {
        WindowGroup {
            MainView()
                .environmentObject(store)
                .frame(minWidth: 1200, minHeight: 800)
        }
    }
}

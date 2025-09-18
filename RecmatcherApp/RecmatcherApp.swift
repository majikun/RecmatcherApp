import SwiftUI
import Foundation

@main
struct RecmatcherApp: App {
    @StateObject private var store = AppStore()
    var body: some SwiftUI.Scene {
        WindowGroup {
            MainView()
                .environmentObject(store)
                .frame(minWidth: 1200, minHeight: 800)
                .onOpenURL { url in
                    guard url.scheme?.lowercased() == "recmatcher" else { return }
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let queryTaskId = components?.queryItems?.first(where: { $0.name == "taskId" })?.value
                    let pathTaskId = url.host ?? url.pathComponents.dropFirst().first
                    let taskId = (queryTaskId ?? pathTaskId)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let taskId, !taskId.isEmpty else { return }
                    Task { @MainActor in
                        store.projectRoot = taskId
                        await store.openProject()
                    }
                }
        }
    }
}

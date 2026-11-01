import SwiftUI

@main
struct DevCacheCleanApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "externaldrive.badge.minus")
                if model.staleBytes > 0 { Text(Model.format(model.staleBytes)) }
            }
            .task { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

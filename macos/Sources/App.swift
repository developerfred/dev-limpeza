import SwiftUI

@main
struct DevCacheCleanApp: App {
    @StateObject private var model = Model()
    @StateObject private var docker = DockerModel()

    var body: some Scene {
        // Main window: opens at launch and from the Dock, so the app is easy to find.
        Window("Dev Cache Clean", id: "main") {
            ContentView(model: model, docker: docker)
                .task {
                    if let dir = Screenshots.directory {
                        try? await Task.sleep(for: .seconds(1))
                        Screenshots.run(into: dir)
                        exit(0)
                    }
                    model.start()
                }
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            ContentView(model: model, docker: docker)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "externaldrive.badge.minus")
                if model.staleBytes > 0 { Text(Model.format(model.staleBytes)) }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

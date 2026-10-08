import SwiftUI

@main
struct RbxportApp: App {
    @State private var model: AppModel

    init() {
        // RBXPORT_FIXTURE_DIR opens a generated fixture library instead of the installed one.
        let backend: any BackendProtocol
        if let dir = ProcessInfo.processInfo.environment["RBXPORT_FIXTURE_DIR"] {
            backend = Backend(fixtureDir: URL(fileURLWithPath: dir))
        } else {
            backend = Backend(cacheDir: Backend.defaultCacheDir)
        }
        _model = State(initialValue: AppModel(backend: backend))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 500)
                .task { model.start() }
        }
    }
}

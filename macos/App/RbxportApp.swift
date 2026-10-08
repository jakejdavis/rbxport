import SwiftUI

@main
struct RbxportApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 500)
                .task { model.start() }
        }
    }
}

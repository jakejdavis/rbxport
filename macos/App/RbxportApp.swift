import SwiftUI

@main
struct RbxportApp: App {
    @State private var model: AppModel
    /// Unit tests load this app as their host; they must never touch the real library.
    private let isUnderTest: Bool

    init() {
        let env = ProcessInfo.processInfo.environment
        isUnderTest = env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        let backend: any BackendProtocol
        if isUnderTest {
            backend = MockBackend(trackCount: 0)
        } else if let dir = env["RBXPORT_FIXTURE_DIR"] {
            // RBXPORT_FIXTURE_DIR opens a generated fixture library instead of the installed one.
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
                .task { if !isUnderTest { model.start() } }
        }
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Find") { model.focusSearch() }.keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Picker(
                    "Key Display",
                    selection: Binding(get: { model.keyStyle }, set: { model.keyStyle = $0 })
                ) {
                    ForEach(KeyStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Button("Reset Columns") { model.resetColumns() }
            }
        }
    }
}

import AppKit
import Foundation
import Testing

@testable import rbxport

@MainActor
private final class FakeWorkspace: FileRevealing {
    var calls: [[URL]] = []
    func activateFileViewerSelecting(_ fileURLs: [URL]) { calls.append(fileURLs) }
}

@MainActor private func window(titled title: String) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
    window.title = title
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
@Suite(.scratchDefaults)
struct DeckKeyGuardTests {
    private func makePlayer() -> PlayerModel {
        let backend = MockBackend(trackCount: 5)
        return PlayerModel(
            backend: backend, waveforms: WaveformService(backend: backend, settle: .zero),
            artwork: ArtworkService(backend: backend, settle: .zero), defaults: scratchDefaults())
    }

    @Test func onlyTheRegisteredMainWindowTakesDeckKeys() {
        let player = makePlayer()
        let main = window(titled: "rbxport")
        let other = window(titled: "rbxport")
        #expect(!player.acceptsKeys(in: main))  // nothing registered yet
        player.mainWindow = main
        #expect(player.acceptsKeys(in: main))
        #expect(!player.acceptsKeys(in: other))
        #expect(!player.acceptsKeys(in: nil))
    }

    @Test func theGuardIgnoresTitlesSoLocalisedWindowsStillCount() {
        let player = makePlayer()
        // A translated title, and a main window that happens to be titled like Settings.
        let main = window(titled: "Einstellungen")
        let sync = window(titled: "Sync-Manager")
        let impostor = window(titled: "Sync Manager")
        player.mainWindow = main
        #expect(player.acceptsKeys(in: main))
        #expect(!player.acceptsKeys(in: sync))
        #expect(!player.acceptsKeys(in: impostor))
    }
}

@MainActor
@Suite(.scratchDefaults)
struct ShowInFinderTests {
    @Test func theWorkspaceGetsTheFileURLs() {
        let workspace = FakeWorkspace()
        let urls = [URL(fileURLWithPath: "/Music/a.mp3"), URL(fileURLWithPath: "/Music/b.wav")]
        revealInFileViewer(urls, using: workspace)
        #expect(workspace.calls == [urls])
    }

    @Test func noURLsMeansNoFinderWindow() {
        let workspace = FakeWorkspace()
        revealInFileViewer([], using: workspace)
        #expect(workspace.calls.isEmpty)
    }

    @Test func aTrackRevealsItsFullPath() async {
        let model = AppModel(backend: MockBackend(), layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        let workspace = FakeWorkspace()
        model.reveal = { revealInFileViewer($0, using: workspace) }
        await model.revealInFinder(trackIDs: ["3"])
        #expect(workspace.calls.count == 1)
        let path = try? await MockBackend().trackPath(id: "3")
        #expect(workspace.calls.first == path.map { [URL(fileURLWithPath: $0)] })
        #expect(workspace.calls.first?.first?.isFileURL == true)
    }

    @Test func noSelectionLeavesFinderAloneAndSaysSo() async {
        let model = AppModel(backend: MockBackend(), layoutStore: isolatedStore())
        let workspace = FakeWorkspace()
        model.reveal = { revealInFileViewer($0, using: workspace) }
        await model.revealInFinder(trackIDs: [])
        #expect(workspace.calls.isEmpty)
        #expect(model.notice == "No file to show.")
    }
}

@MainActor
struct SidebarIconTests {
    @Test func iconsAreAccentTintedAndWhiteOnASelectedRow() {
        #expect(SidebarCellView.iconTint(emphasized: false) == .controlAccentColor)
        #expect(SidebarCellView.iconTint(emphasized: true) == .alternateSelectedControlTextColor)
    }
}

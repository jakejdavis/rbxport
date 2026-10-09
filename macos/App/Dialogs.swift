import AppKit
import Foundation
import UniformTypeIdentifiers

/// The native panels and alerts the editing commands ask the user through, behind closures so
/// tests answer them without a window.
@MainActor
struct Dialogs {
    /// A warning alert with a destructive default button; true when confirmed.
    var confirm: @MainActor (_ message: String, _ detail: String, _ button: String) async -> Bool
    /// An open panel for audio files (and folders when `directories`); empty when cancelled.
    var chooseAudio: @MainActor (_ prompt: String, _ directories: Bool) async -> [URL]
    /// An open panel for one file of any of the types; nil when cancelled.
    var chooseFile: @MainActor (_ prompt: String, _ types: [UTType]) async -> URL?
    /// An open panel for one folder; nil when cancelled.
    var chooseFolder: @MainActor (_ prompt: String) async -> URL?
    /// An informational alert with a body of several lines.
    var inform: @MainActor (_ message: String, _ detail: String) async -> Void

    nonisolated static let audioExtensions = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus"]

    static let live = Dialogs(
        confirm: { message, detail, button in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = message
            alert.informativeText = detail
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        },
        chooseAudio: { prompt, directories in
            let panel = NSOpenPanel()
            panel.message = prompt
            panel.prompt = "Import"
            panel.canChooseFiles = !directories
            panel.canChooseDirectories = directories
            panel.allowsMultipleSelection = true
            if !directories {
                panel.allowedContentTypes = audioExtensions.compactMap { UTType(filenameExtension: $0) }
            }
            return panel.runModal() == .OK ? panel.urls : []
        },
        chooseFile: { prompt, types in
            let panel = NSOpenPanel()
            panel.message = prompt
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            if !types.isEmpty { panel.allowedContentTypes = types }
            return panel.runModal() == .OK ? panel.url : nil
        },
        chooseFolder: { prompt in
            let panel = NSOpenPanel()
            panel.message = prompt
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            return panel.runModal() == .OK ? panel.url : nil
        },
        inform: { message, detail in
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = message
            alert.informativeText = detail
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
        })
}

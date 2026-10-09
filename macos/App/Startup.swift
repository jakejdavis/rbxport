import AppKit
import Observation
import SwiftUI

// MARK: - What went wrong, and what can be done

/// What can be done from the library-problem view.
enum ProblemAction: Equatable, Sendable {
    /// Try opening the library again.
    case retry
    /// Make a new, empty library (the New Library sheet).
    case createLibrary
    /// Open the Report a Problem window, which shows the log.
    case showLog
    case quit
}

enum ProblemKind: Equatable, Sendable {
    /// No database where one should be, and one can be made.
    case missing
    /// rekordbox's settings are not there.
    case notInstalled
    /// The database would not unlock: wrong or missing key, or not a database.
    case wrongKey
    /// A database layout rbxport does not know.
    case schema
    /// Anything else (a locked or damaged file).
    case unreadable
}

/// The words and buttons of the library-problem view for one `LibraryProblem`.
struct LibraryProblemInfo: Equatable, Sendable {
    var kind: ProblemKind
    var title: String
    var message: String
    /// The database that would be made, for `.missing`.
    var path: String?
    var hint: String
    /// In the order the buttons are drawn; the first is the default.
    var actions: [ProblemAction]

    /// The React `NewLibraryDialog` text for a missing library; for the others the core's own message
    /// (React puts it in the status bar) with a line on what to try.
    static func describe(_ problem: LibraryProblem) -> LibraryProblemInfo {
        switch problem {
        case .missing(let masterDb):
            return LibraryProblemInfo(
                kind: .missing, title: "No rekordbox Library",
                message: "rekordbox isn't installed and there is no rekordbox database. Would you like to create a new database?",
                path: masterDb, hint: "A new library is empty. rbxport makes it the way rekordbox would, so rekordbox can open it later.",
                actions: [.createLibrary, .retry, .quit])
        case .failed(let message):
            let kind = classify(message)
            return LibraryProblemInfo(
                kind: kind, title: "Could not open the library", message: message, path: nil, hint: hint(for: kind),
                actions: [.retry, .showLog, .quit])
        }
    }

    static func classify(_ message: String) -> ProblemKind {
        let text = message.lowercased()
        if text.contains("does not appear to be installed") { return .notInstalled }
        if text.contains("derive the database key") || text.contains("not a database") || text.contains("encrypted")
            || text.contains("passphrase")
        {
            return .wrongKey
        }
        if text.contains("unexpected database schema") { return .schema }
        return .unreadable
    }

    static func hint(for kind: ProblemKind) -> String {
        switch kind {
        case .missing: "A new library is empty. rbxport makes it the way rekordbox would, so rekordbox can open it later."
        case .notInstalled: "rbxport opens ~/Library/Pioneer/rekordbox read-only. Is rekordbox installed?"
        case .wrongKey:
            "The database would not unlock: the key rekordbox keeps for it did not fit, or the file is not a rekordbox database. rbxport never changes it."
        case .schema: "This database layout is not one rbxport knows yet. Open it once in rekordbox, or update rbxport."
        case .unreadable: "rbxport opens your rekordbox library read-only. If rekordbox is busy with it, wait a moment and try again."
        }
    }
}

// MARK: - The New Library sheet

/// Picks where a new library goes and what its folder is called, then makes it and loads it.
@MainActor @Observable
final class NewLibraryModel: Identifiable {
    let id = UUID()
    let plan: NewLibraryPlan
    private let backend: any BackendProtocol
    private let dialogs: @MainActor () -> Dialogs
    /// Called when the sheet is done: with the outcome of the load, or nil when cancelled.
    var onFinished: (LoadOutcome?) -> Void = { _ in }

    /// The folder the library's folder goes in, and the folder's own name.
    var parent: String
    var name: String
    private(set) var isCreating = false
    private(set) var error: String?

    init(plan: NewLibraryPlan, backend: any BackendProtocol, dialogs: @escaping @MainActor () -> Dialogs) {
        self.plan = plan
        self.backend = backend
        self.dialogs = dialogs
        let folder = URL(fileURLWithPath: plan.masterDb).deletingLastPathComponent()
        parent = folder.deletingLastPathComponent().path
        name = folder.lastPathComponent
    }

    var canChoose: Bool { plan.canChooseLocation }

    /// The folder the library will be made in.
    var folder: String {
        canChoose ? URL(fileURLWithPath: parent).appendingPathComponent(name.trimmingCharacters(in: .whitespaces)).path
            : URL(fileURLWithPath: plan.masterDb).deletingLastPathComponent().path
    }

    /// The database that will be made.
    var masterDb: String { canChoose ? folder + "/master.db" : plan.masterDb }

    /// Why the name will not do, or nil.
    var nameProblem: String? {
        guard canChoose else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Give the library a name." }
        if trimmed == "." || trimmed == ".." || trimmed.contains("/") || trimmed.contains(":") {
            return "A name cannot contain \u{201C}/\u{201D} or \u{201C}:\u{201D}."
        }
        if trimmed.utf8.count > 255 { return "That name is too long." }
        return nil
    }

    var canCreate: Bool { !isCreating && nameProblem == nil }

    func chooseParent() async {
        guard canChoose, !isCreating else { return }
        if let url = await dialogs().chooseFolder("Choose where to keep the new library") {
            parent = url.path
            error = nil
        }
    }

    func create() async {
        guard canCreate else { return }
        isCreating = true
        error = nil
        defer { isCreating = false }
        do {
            let outcome = try await backend.createLibrary(folder: canChoose ? folder : nil)
            onFinished(outcome)
        } catch {
            self.error = describe(error)
        }
    }

    func cancel() { if !isCreating { onFinished(nil) } }
}

extension AppModel {
    /// What the library-problem view shows, or nil when there is no problem.
    var libraryProblemInfo: LibraryProblemInfo? {
        switch phase {
        case .failed(let message): LibraryProblemInfo.describe(.failed(message: message))
        case .missing(let path): LibraryProblemInfo.describe(.missing(masterDb: path))
        case .loading, .ready: nil
        }
    }

    /// Opens the library again, as launch would; the outcome arrives as an event.
    func retryLoad() async {
        phase = .loading
        _ = await backend.loadLibrary()
    }

    /// Asks the core where a library would go and opens the sheet. A library that has appeared
    /// since is loaded instead.
    func openNewLibrary() async {
        do {
            guard let plan = try await backend.planNewLibrary() else {
                await retryLoad()
                return
            }
            let sheet = NewLibraryModel(plan: plan, backend: backend, dialogs: { [weak self] in self?.dialogs ?? .live })
            sheet.onFinished = { [weak self] _ in self?.newLibrary = nil }
            newLibrary = sheet
        } catch {
            notice = describe(error)
        }
    }

    func perform(_ action: ProblemAction) async {
        switch action {
        case .retry: await retryLoad()
        case .createLibrary: await openNewLibrary()
        case .showLog: openReportWindow()
        case .quit: terminate()
        }
    }

    /// Asks the main window to open the Report a Problem window.
    func openReportWindow() { reportWindowRequests += 1 }
}

// MARK: - Views

/// The full-window view for a library that did not load.
struct LibraryProblemView: View {
    let info: LibraryProblemInfo
    let perform: (ProblemAction) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: info.kind == .missing ? "externaldrive.badge.plus" : "exclamationmark.triangle")
                .font(.system(size: 44)).foregroundStyle(info.kind == .missing ? Color.accentColor : .orange)
                .accessibilityHidden(true)
            Text(info.title).font(.title.bold())
            Text(info.message).multilineTextAlignment(.center).frame(maxWidth: 460)
                .textSelection(.enabled)
                .accessibilityIdentifier("problem-message")
            if let path = info.path {
                Text(path).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle).frame(maxWidth: 520)
                    .accessibilityIdentifier("problem-path")
            }
            Text(info.hint).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 12) {
                ForEach(Array(info.actions.enumerated()), id: \.offset) { index, action in
                    Button(Self.title(action)) { perform(action) }
                        .keyboardShortcut(index == 0 ? .defaultAction : nil)
                        .accessibilityIdentifier("problem-\(Self.identifier(action))")
                }
            }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func title(_ action: ProblemAction) -> String {
        switch action {
        case .retry: "Try Again"
        case .createLibrary: "Create New Library\u{2026}"
        case .showLog: "Show Log\u{2026}"
        case .quit: "Quit"
        }
    }

    static func identifier(_ action: ProblemAction) -> String {
        switch action {
        case .retry: "retry"
        case .createLibrary: "create"
        case .showLog: "log"
        case .quit: "quit"
        }
    }
}

/// The sheet that makes a new library.
struct NewLibrarySheet: View {
    let model: NewLibraryModel

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("New Library").font(.title2.bold())
            Text(model.canChoose
                ? "Choose where rbxport keeps the new library and what its folder is called. It starts empty."
                : "rekordbox's settings already say where the library goes. rbxport will make it there, empty.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.canChoose {
                Form {
                    LabeledContent("Location") {
                        HStack {
                            Text(model.parent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Choose\u{2026}") { Task { await model.chooseParent() } }
                                .accessibilityIdentifier("newlibrary-choose")
                        }
                    }
                    TextField("Name", text: $model.name)
                        .accessibilityIdentifier("newlibrary-name")
                    if let problem = model.nameProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                }
                .formStyle(.columns)
            }
            LabeledContent("Database") {
                Text(model.masterDb).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled).accessibilityIdentifier("newlibrary-path")
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    .accessibilityIdentifier("newlibrary-error")
            }
            HStack {
                if model.isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }.disabled(model.isCreating)
                Button(model.isCreating ? "Creating\u{2026}" : "Create") { Task { await model.create() } }
                    .keyboardShortcut(.defaultAction).disabled(!model.canCreate)
                    .accessibilityIdentifier("newlibrary-create")
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

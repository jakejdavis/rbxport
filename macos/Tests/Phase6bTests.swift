import Foundation
import Testing

@testable import rbxport

private func backup(_ name: String, at seconds: Double, bytes: UInt64 = 5_000_000) -> BackupInfo {
    BackupInfo(
        name: name, path: "/tmp/rbxport-backups/\(name)", bytes: bytes, createdAt: UInt64(seconds * 1000),
        includesAnalysis: true, includesArtwork: true)
}

private func running(_ phase: BackupPhase, copied: UInt64 = 0, total: UInt64 = 0, item: String? = nil) -> BackupProgress {
    BackupProgress(running: true, phase: phase, copiedBytes: copied, totalBytes: total, error: nil, path: nil, currentItem: item)
}

// MARK: - Backups

@MainActor
@Suite(.scratchDefaults)
struct BackupsModelTests {
    private func make(
        folder: URL? = nil, confirms: Bool = true, script: (@Sendable (inout MockChromeScript) -> Void)? = nil
    ) async -> (BackupsModel, MockBackend, StubDialogs) {
        let backend = MockBackend(trackCount: 5)
        if let script { await backend.scriptChrome(script) }
        let stub = StubDialogs()
        stub.confirms = confirms
        stub.folder = folder
        let model = BackupsModel(backend: backend, dialogs: { stub.dialogs })
        return (model, backend, stub)
    }

    @Test func loadReadsTheFolderTheListAndAnIdleJob() async {
        let (model, _, _) = await make { $0.directory = "/tmp/b"; $0.backups = [backup("rbexport-1.zip", at: 1_000)] }
        await model.load()
        #expect(model.directory == "/tmp/b" && model.backups.count == 1 && model.loaded)
        #expect(model.progress == nil && !model.isRunning)
    }

    @Test func startingRunsOneJobAndASecondStartIsIgnored() async {
        let (model, backend, _) = await make()
        await model.start()
        await model.start()
        #expect(model.isRunning && model.statusText == "Backing up your library")
        let calls = await backend.chromeCalls()
        #expect(calls.filter { $0 == "startBackup" }.count == 1)
    }

    @Test func aRefusedStartShowsWhyAndRunsNothing() async {
        let (model, _, _) = await make { $0.startError = .Internal(message: "A backup is already running.", detail: nil) }
        await model.start()
        #expect(!model.isRunning && model.error == "A backup is already running.")
    }

    @Test func progressEventsGiveTheBarTheBytesAndTheWords() async {
        let (model, _, _) = await make()
        model.handle(progress: running(.copying, copied: 50_000_000, total: 200_000_000, item: "ANLZ0000.DAT"))
        #expect(model.fraction == 0.25)
        #expect(model.byteText == "47.7 MB of 190.7 MB")
        #expect(model.itemText == "ANLZ0000.DAT")
        model.handle(progress: running(.compressing, copied: 1, total: 2))
        #expect(model.statusText == "Finishing your compressed ZIP backup.")
        model.handle(progress: running(.validating))
        #expect(model.statusText == "Checking the saved files before finishing.")
        #expect(model.fraction == nil, "no total yet is an indeterminate bar")
    }

    @Test func completingRefreshesTheListAndClearsTheError() async {
        let (model, backend, _) = await make()
        await model.load()
        model.handle(progress: BackupProgress(running: false, phase: .failed, copiedBytes: 0, totalBytes: 0, error: "Disk full", path: nil, currentItem: nil))
        #expect(model.error == "Disk full" && !model.isRunning)
        await backend.finishBackup(backup("rbexport-20261009-1500.zip", at: 1_000))
        model.handle(progress: await backend.backupProgress())
        #expect(await eventually { model.backups.count == 1 })
        #expect(model.progress?.phase == .complete && model.error == nil)
    }

    @Test func aBackupEventReachesTheModelThroughTheApp() async {
        let backend = MockBackend(trackCount: 5)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.phase == .ready })
        await backend.moveBackup(running(.copying, copied: 1, total: 4))
        #expect(await eventually { model.backups.fraction == 0.25 })
    }

    @Test func stoppingAsksTheCoreAndSaysSo() async {
        let (model, backend, _) = await make()
        await model.start()
        await model.cancel()
        #expect(model.isStopping && model.statusText == "Removing the unfinished backup\u{2026}")
        #expect(await backend.chromeCalls().contains("cancelBackup"))
        model.handle(progress: BackupProgress(running: false, phase: .cancelled, copiedBytes: 0, totalBytes: 0, error: nil, path: nil, currentItem: nil))
        #expect(!model.isRunning && !model.isStopping)
    }

    @Test func deletingAsksFirstAndOnlyThenRemoves() async {
        let item = backup("rbexport-1.zip", at: 1_790_000_000)
        let (model, backend, stub) = await make(confirms: false) { $0.backups = [backup("rbexport-1.zip", at: 1_790_000_000)] }
        await model.load()
        await model.delete(item)
        #expect(stub.confirmed.count == 1 && stub.confirmed[0].detail == "This cannot be undone.")
        #expect(stub.confirmed[0].message.hasPrefix("Delete the backup from "))
        #expect(model.backups.count == 1, "declined: nothing happens")
        #expect(!(await backend.chromeCalls().contains { $0.hasPrefix("deleteBackup") }))
        stub.confirms = true
        await model.delete(item)
        #expect(model.backups.isEmpty)
        #expect(await backend.chromeCalls().contains("deleteBackup(\(item.path))"))
    }

    @Test func aRefusedDeleteIsShownAndTheArchiveStays() async {
        let item = backup("rbexport-1.zip", at: 1_000)
        let (model, _, _) = await make { $0.backups = [backup("rbexport-1.zip", at: 1_000)]; $0.deleteError = .Internal(message: "Not a managed backup.", detail: nil) }
        await model.load()
        await model.delete(item)
        #expect(model.error == "Not a managed backup." && model.backups.count == 1)
    }

    @Test func choosingAFolderRemembersItAndRefusesWhileRunning() async {
        let (model, backend, stub) = await make(folder: URL(fileURLWithPath: "/tmp/elsewhere"))
        await model.load()
        await model.chooseDirectory()
        #expect(model.directory == "/tmp/elsewhere")
        #expect(await backend.chromeCalls().contains("setBackupDirectory(/tmp/elsewhere)"))
        stub.folder = nil
        await model.chooseDirectory()
        #expect(model.directory == "/tmp/elsewhere", "cancelled: unchanged")
        await model.start()
        await model.chooseDirectory()
        #expect(model.error == "Wait for the current backup to finish before changing its folder.")
    }

    @Test func aFolderTheCoreRefusesKeepsTheOldOne() async {
        let (model, _, _) = await make(folder: URL(fileURLWithPath: "/System")) {
            $0.directory = "/tmp/old"; $0.directoryError = .Internal(message: "The backup folder is not writable.", detail: nil)
        }
        await model.load()
        await model.chooseDirectory()
        #expect(model.directory == "/tmp/old" && model.error == "The backup folder is not writable.")
    }

    @Test func theFolderAndAnArchiveAreShownInTheFinder() async {
        let (model, backend, _) = await make { $0.directory = "/tmp/b" }
        var opened: [URL] = []
        var revealed: [URL] = []
        model.openFolder = { opened.append($0) }
        model.revealFile = { revealed.append($0) }
        await model.showFolder()
        model.reveal(backup("rbexport-1.zip", at: 1))
        #expect(opened == [URL(fileURLWithPath: "/tmp/b", isDirectory: true)])
        #expect(revealed == [URL(fileURLWithPath: "/tmp/rbxport-backups/rbexport-1.zip")])
        #expect(await backend.chromeCalls().contains("ensureBackupDirectory"))
    }

    @Test func aHiddenInternalMessageIsReadFromItsDetail() {
        let hidden = FfiError.Internal(message: "Something went wrong inside rbxport.", detail: "Backup: A backup for this minute already exists.")
        #expect(BackupsModel.message(hidden) == "A backup for this minute already exists.")
        #expect(BackupsModel.message(FfiError.NotFound(message: "gone", detail: nil)) == "gone")
    }

    @Test func howLongAgoIsWordedAsReactWordsIt() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func text(_ ago: Double) -> String { BackupsModel.relativeText(backup("x", at: 1_000_000 - ago), now: now) }
        #expect(text(5) == "just now")
        #expect(text(60) == "1 minute ago" && text(180) == "3 minutes ago")
        #expect(text(3600) == "1 hour ago" && text(7200) == "2 hours ago")
        #expect(text(86_400) == "1 day ago" && text(3 * 86_400) == "3 days ago")
    }
}

// MARK: - The bug report

@MainActor
@Suite(.scratchDefaults)
struct BugReportTests {
    private static let summary = LibrarySummary(trackCount: 300, playlistCount: 12, readOnly: true, dbVersion: 6000, loadMs: 480)
    private static let when = Date(timeIntervalSince1970: 1_790_000_000)

    private func report(library: LibrarySummary? = summary, note: String? = nil) -> DiagnosticsReport {
        DiagnosticsReport(
            system: MockChromeScript().report, health: AudioHealth(load: 0.125, xruns: 2), library: library, libraryNote: note, generated: Self.when)
    }

    @Test func theTextNamesTheBuildTheMachineTheProcessTheAudioAndTheLibrary() {
        let text = report().text(timeZone: TimeZone(identifier: "UTC")!)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "rbxport diagnostics")
        #expect(lines[1] == "Generated: 2026-09-21 14:13 +0000")
        for expected in [
            "System information", "rbxport 0.1.0", "OS: macos 26.0", "Architecture: aarch64", "Process CPU: 3.5% of one core",
            "Resident memory: 412.2 MiB", "Threads: 31", "Open files: 64", "Audio deadline load: 12.5%", "Audio callback overruns: 2",
            "Library", "Tracks: 300", "Playlists: 12", "Mode: Read-only", "Schema version: 6000", "Loaded in 480 ms",
            "Application log (latest file)", "/tmp/rbxport/logs/rbxport.2026-10-09.log",
        ] {
            #expect(lines.contains(expected), "missing: \(expected)")
        }
    }

    @Test func theLogComesLastAndVerbatim() {
        let text = report().text(timeZone: TimeZone(identifier: "UTC")!)
        #expect(text.hasSuffix("2026-10-09T10:00:00Z DEBUG rbl_app: started\n"))
        #expect(!text.contains("redacted"))
    }

    @Test func aLibraryThatDidNotLoadSaysWhyInsteadOfNumbers() {
        let lines = report(library: nil, note: "Did not load: database is locked").libraryLines
        #expect(lines == ["Library", "Did not load: database is locked"])
        #expect(report(library: nil).libraryLines == ["Library", "Not loaded."])
    }

    @Test func missingOptionalReadingsAreLeftOut() {
        var r = report()
        r.system.threads = nil
        r.system.openFiles = nil
        #expect(!r.systemLines.contains { $0.hasPrefix("Threads") || $0.hasPrefix("Open files") })
    }

    @Test func refreshingReadsTheCoreAndTheLibraryTogether() async {
        let backend = MockBackend(trackCount: 5)
        let model = BugReportModel(backend: backend, library: { (Self.summary, nil) })
        model.now = { Self.when }
        #expect(model.report == nil && model.text == "")
        await model.refresh()
        #expect(model.report?.library == Self.summary && model.report?.health.xruns == 2)
        #expect(model.text.contains("Tracks: 300"))
        #expect(await backend.chromeCalls().contains("systemReport"))
    }

    @Test func copyingPutsTheWholeReportOnThePasteboardAndSendsNothing() async {
        let backend = MockBackend(trackCount: 5)
        let model = BugReportModel(backend: backend, library: { (nil, "Still loading.") })
        var pasted: [String] = []
        model.copy = { pasted.append($0) }
        model.copyReport()
        #expect(pasted.isEmpty, "nothing to copy before the report is read")
        await model.refresh()
        model.copyReport()
        #expect(pasted == [model.text] && model.copied)
        #expect(model.message == "Report copied. It has not been sent anywhere.")
        #expect(pasted[0].contains("Still loading."))
    }

    @Test func revealLogShowsTheFileOrSaysThereIsNone() async {
        let backend = MockBackend(trackCount: 5)
        let model = BugReportModel(backend: backend, library: { (nil, nil) })
        var revealed: [URL] = []
        model.revealFile = { revealed.append($0) }
        await model.refresh()
        #expect(model.canRevealLog)
        model.revealLog()
        #expect(revealed == [URL(fileURLWithPath: "/tmp/rbxport/logs/rbxport.2026-10-09.log")])

        await backend.scriptChrome { $0.report.logPath = nil }
        await model.refresh()
        #expect(!model.canRevealLog)
        model.revealLog()
        #expect(revealed.count == 1 && model.message == "No application log was found.")
    }

    @Test func theAppModelReportsItsOwnLibraryState() async {
        let backend = MockBackend(trackCount: 7)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        await model.bugReport.refresh()
        #expect(model.bugReport.report?.libraryNote == "Still loading.")
        model.start()
        #expect(await eventually { model.phase == .ready })
        await model.bugReport.refresh()
        #expect(model.bugReport.report?.library?.trackCount == 7)
    }
}

// MARK: - Startup: the library-problem view

@MainActor
@Suite(.scratchDefaults)
struct LibraryProblemTests {
    @Test func aMissingLibraryUsesReactsWordsAndOffersCreateRetryQuit() {
        let info = LibraryProblemInfo.describe(.missing(masterDb: "/Users/dj/Library/Pioneer/rekordbox/master.db"))
        #expect(info.kind == .missing && info.title == "No rekordbox Library")
        #expect(info.message == "rekordbox isn't installed and there is no rekordbox database. Would you like to create a new database?")
        #expect(info.path == "/Users/dj/Library/Pioneer/rekordbox/master.db")
        #expect(info.actions == [.createLibrary, .retry, .quit])
    }

    @Test(arguments: [
        ("rekordbox does not appear to be installed: x not found", ProblemKind.notInstalled),
        ("could not derive the database key: bad", .wrongKey),
        ("could not open the database: file is not a database", .wrongKey),
        ("unexpected database schema: v9", .schema),
        ("database is locked", .unreadable),
    ])
    func aFailureIsSortedByWhatTheCoreSaid(message: String, kind: ProblemKind) {
        let info = LibraryProblemInfo.describe(.failed(message: message))
        #expect(info.kind == kind && info.message == message && info.path == nil)
        #expect(info.actions == [.retry, .showLog, .quit])
        #expect(!info.hint.isEmpty)
    }

    @Test func aFailedLoadShowsTheFullWindowProblemWithTheCoreMessage() async {
        let model = AppModel(backend: MockBackend(failLoad: "could not derive the database key: x"), layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.phase != .loading })
        #expect(model.libraryProblemInfo?.kind == .wrongKey)
        #expect(model.libraryProblemInfo?.message == "could not derive the database key: x")
    }

    @Test func aMissingEventIsItsOwnPhaseNotAFailureMessage() async {
        let backend = MockBackend(trackCount: 5)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        await model.handle(.libraryProblem(problem: .missing(masterDb: "/x/master.db")))
        #expect(model.phase == .missing("/x/master.db"))
        #expect(model.libraryProblemInfo?.kind == .missing)
        #expect(AppModel(backend: backend, layoutStore: isolatedStore()).libraryProblemInfo == nil)
    }

    @Test func tryAgainLoadsAgainAndShowsTheLibraryWhenItIsThere() async {
        let backend = MockBackend(trackCount: 9)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.phase == .ready })
        await model.handle(.libraryProblem(problem: .failed(message: "database is locked")))
        #expect(model.libraryProblemInfo != nil)
        await model.perform(.retry)
        #expect(await eventually { model.phase == .ready })
        #expect(model.libraryProblemInfo == nil)
    }

    @Test func quitAndShowLogDoWhatTheyAreCalled() async {
        let model = AppModel(backend: MockBackend(trackCount: 1), layoutStore: isolatedStore())
        var quits = 0
        model.terminate = { quits += 1 }
        await model.perform(.quit)
        #expect(quits == 1)
        let before = model.reportWindowRequests
        await model.perform(.showLog)
        #expect(model.reportWindowRequests == before + 1)
    }

    @Test func everyActionHasAButtonTitleAndId() {
        for action in [ProblemAction.retry, .createLibrary, .showLog, .quit] {
            #expect(!LibraryProblemView.title(action).isEmpty && !LibraryProblemView.identifier(action).isEmpty)
        }
    }
}

// MARK: - Startup: a new library

@MainActor
@Suite(.scratchDefaults)
struct NewLibraryTests {
    private static let choosable = NewLibraryPlan(masterDb: "/Users/dj/Library/Pioneer/rekordbox/master.db", canChooseLocation: true)
    private static let fixed = NewLibraryPlan(masterDb: "/Volumes/Lib/rekordbox/master.db", canChooseLocation: false)

    private func sheet(_ plan: NewLibraryPlan, backend: MockBackend = MockBackend(trackCount: 0), stub: StubDialogs = StubDialogs()) -> NewLibraryModel {
        NewLibraryModel(plan: plan, backend: backend, dialogs: { stub.dialogs })
    }

    @Test func theSheetStartsAtTheCoresPlan() {
        let m = sheet(Self.choosable)
        #expect(m.parent == "/Users/dj/Library/Pioneer" && m.name == "rekordbox")
        #expect(m.folder == "/Users/dj/Library/Pioneer/rekordbox" && m.masterDb == Self.choosable.masterDb)
        #expect(m.canCreate && m.nameProblem == nil)
    }

    @Test func aNewNameAndLocationChangeWhereTheDatabaseGoes() async {
        let stub = StubDialogs()
        stub.folder = URL(fileURLWithPath: "/Volumes/Music")
        let m = sheet(Self.choosable, stub: stub)
        await m.chooseParent()
        m.name = "  My DJ Library "
        #expect(m.folder == "/Volumes/Music/My DJ Library" && m.masterDb == "/Volumes/Music/My DJ Library/master.db")
    }

    @Test(arguments: ["", "   ", ".", "..", "a/b", "a:b"])
    func aBadNameCannotBeCreated(name: String) {
        let m = sheet(Self.choosable)
        m.name = name
        #expect(m.nameProblem != nil && !m.canCreate)
    }

    @Test func whenRekordboxsOptionsFixTheFolderTheSheetCannotMoveIt() async {
        let stub = StubDialogs()
        stub.folder = URL(fileURLWithPath: "/tmp/else")
        let m = sheet(Self.fixed, stub: stub)
        await m.chooseParent()
        m.name = "ignored/"
        #expect(!m.canChoose && m.nameProblem == nil && m.canCreate)
        #expect(m.masterDb == "/Volumes/Lib/rekordbox/master.db" && m.folder == "/Volumes/Lib/rekordbox")
    }

    @Test func creatingSendsTheChosenFolderAndFinishesWithTheLoadOutcome() async {
        let backend = MockBackend(trackCount: 0)
        let m = sheet(Self.choosable, backend: backend)
        m.name = "Club"
        var finished: [LoadOutcome?] = []
        m.onFinished = { finished.append($0) }
        await m.create()
        #expect(await backend.chromeCalls() == ["createLibrary(/Users/dj/Library/Pioneer/Club)"])
        #expect(finished == [.ready] && !m.isCreating && m.error == nil)
    }

    @Test func aFixedPlanSendsNoFolder() async {
        let backend = MockBackend(trackCount: 0)
        let m = sheet(Self.fixed, backend: backend)
        await m.create()
        #expect(await backend.chromeCalls() == ["createLibrary(nil)"])
    }

    @Test func aFailureStaysOnTheSheetWithTheMessage() async {
        let backend = MockBackend(trackCount: 0)
        await backend.scriptChrome { $0.createError = .Internal(message: "Could not make the library: disk full", detail: nil) }
        let m = sheet(Self.choosable, backend: backend)
        var finished = 0
        m.onFinished = { _ in finished += 1 }
        await m.create()
        #expect(m.error == "Could not make the library: disk full" && finished == 0 && m.canCreate)
    }

    @Test func cancellingFinishesWithNothing() {
        let m = sheet(Self.choosable)
        var finished: [LoadOutcome?] = []
        m.onFinished = { finished.append($0) }
        m.cancel()
        #expect(finished.count == 1 && finished[0] == nil)
    }

    @Test func fromTheProblemViewToALoadedLibrary() async {
        let backend = MockBackend(trackCount: 4)
        await backend.scriptChrome { $0.plan = NewLibraryPlan(masterDb: "/tmp/x/rekordbox/master.db", canChooseLocation: true) }
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.phase == .ready })
        await model.handle(.libraryProblem(problem: .missing(masterDb: "/tmp/x/rekordbox/master.db")))
        #expect(model.phase == .missing("/tmp/x/rekordbox/master.db"))
        await model.perform(.createLibrary)
        let sheet = model.newLibrary
        #expect(sheet?.masterDb == "/tmp/x/rekordbox/master.db")
        await sheet?.create()
        #expect(model.newLibrary == nil, "the sheet closes")
        #expect(await eventually { model.phase == .ready })
    }

    @Test func aLibraryThatAppearedMeanwhileIsLoadedNotReplaced() async {
        let backend = MockBackend(trackCount: 4)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.phase == .ready })
        await model.handle(.libraryProblem(problem: .missing(masterDb: "/tmp/x/master.db")))
        await model.perform(.createLibrary)
        #expect(model.newLibrary == nil)
        #expect(await eventually { model.phase == .ready })
        #expect(!(await backend.chromeCalls().contains { $0.hasPrefix("createLibrary") }))
    }
}

// MARK: - Window geometry

@MainActor
@Suite(.scratchDefaults)
struct WindowGeometryTests {
    private let screen = CGRect(x: 0, y: 25, width: 1600, height: 875)

    @Test func widthsStartAtReactsDefaultsAndWriteNothing() {
        let d = scratchDefaults()
        let store = WindowGeometryStore(defaults: d)
        #expect(store.initialSidebarWidth == 240 && store.initialInfoWidth == 280 && store.savedFrame == nil)
        #expect(d.object(forKey: WindowGeometryStore.Keys.sidebarWidth) == nil)
    }

    @Test func widthsAreKeptClampedAndRestoredOnTheNextLaunch() {
        let d = scratchDefaults()
        let store = WindowGeometryStore(defaults: d)
        store.setSidebarWidth(310)
        store.setInfoWidth(333.5)
        let next = WindowGeometryStore(defaults: d)
        #expect(next.initialSidebarWidth == 310 && next.initialInfoWidth == 333.5)
        d.set(5_000.0, forKey: WindowGeometryStore.Keys.sidebarWidth)
        d.set("wide", forKey: WindowGeometryStore.Keys.infoWidth)
        let bad = WindowGeometryStore(defaults: d)
        #expect(bad.initialSidebarWidth == 400 && bad.initialInfoWidth == 280)
    }

    @Test func aCollapsedPanelAndTinyWigglesAreNotRemembered() {
        let d = scratchDefaults()
        let store = WindowGeometryStore(defaults: d)
        store.setSidebarWidth(0)
        store.setInfoWidth(0)
        store.setSidebarWidth(240.4)
        #expect(d.object(forKey: WindowGeometryStore.Keys.sidebarWidth) == nil)
        #expect(d.object(forKey: WindowGeometryStore.Keys.infoWidth) == nil)
        store.setSidebarWidth(260)
        #expect(d.double(forKey: WindowGeometryStore.Keys.sidebarWidth) == 260)
    }

    @Test func theFrameRoundTripsAndNonsenseIsIgnored() {
        let d = scratchDefaults()
        let store = WindowGeometryStore(defaults: d)
        store.saveFrame(CGRect(x: 100, y: 120, width: 1280, height: 900))
        #expect(WindowGeometryStore(defaults: d).savedFrame == CGRect(x: 100, y: 120, width: 1280, height: 900))
        store.saveFrame(CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(store.savedFrame?.width == 1280, "a collapsed frame is not kept")
        d.set("garbage", forKey: WindowGeometryStore.Keys.mainFrame)
        #expect(WindowGeometryStore(defaults: d).savedFrame == nil)
    }

    @Test func aSavedFrameThatFitsComesBackAsItWas() {
        let frame = CGRect(x: 100, y: 120, width: 1280, height: 700)
        #expect(WindowGeometryStore.fit(frame, in: screen, minSize: WindowGeometryStore.minimumWindowSize) == frame)
    }

    @Test func aFrameFromABiggerScreenIsShrunkThenMovedIn() {
        let big = CGRect(x: 2000, y: -300, width: 2400, height: 1500)
        let fitted = WindowGeometryStore.fit(big, in: screen, minSize: WindowGeometryStore.minimumWindowSize)
        #expect(fitted.size == CGSize(width: 1600, height: 875))
        #expect(fitted.origin == CGPoint(x: 0, y: 25))
    }

    @Test func aFrameOffTheEdgeIsPulledBackAndNeverGetsSmallerThanTheMinimum() {
        let off = CGRect(x: 1500, y: 800, width: 1000, height: 700)
        let fitted = WindowGeometryStore.fit(off, in: screen, minSize: WindowGeometryStore.minimumWindowSize)
        #expect(fitted.maxX == 1600 && fitted.maxY == 900 && fitted.size == off.size)
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 200)
        let grown = WindowGeometryStore.fit(tiny, in: screen, minSize: WindowGeometryStore.minimumWindowSize)
        #expect(grown.size == WindowGeometryStore.minimumWindowSize)
    }

    @Test func restoredFrameIsNilWithoutASavedOne() {
        #expect(WindowGeometryStore(defaults: scratchDefaults()).restoredFrame(in: screen) == nil)
    }

    @Test func theAppModelOwnsOneStoreOverItsDefaults() {
        let store = isolatedStore()
        let model = AppModel(backend: MockBackend(trackCount: 1), layoutStore: store)
        model.geometry.setSidebarWidth(300)
        #expect(store.defaults.double(forKey: WindowGeometryStore.Keys.sidebarWidth) == 300)
    }

    // The player/browser split and the deck panel are the player model's, kept under its own keys.

    @Test func theDeckPanelBeingHiddenSurvivesARelaunch() {
        let store = isolatedStore()
        let first = AppModel(backend: MockBackend(trackCount: 1), layoutStore: store)
        #expect(first.player.panelOpen)
        first.player.panelOpen = false
        let second = AppModel(backend: MockBackend(trackCount: 1), layoutStore: store)
        #expect(!second.player.panelOpen && second.player.layout == .browser)
        second.player.panelOpen = true
        let third = AppModel(backend: MockBackend(trackCount: 1), layoutStore: store)
        #expect(third.player.panelOpen && third.player.layout == .one)
    }

    @Test func thePlayerBrowserSplitSurvivesARelaunch() {
        let store = isolatedStore()
        let first = AppModel(backend: MockBackend(trackCount: 1), layoutStore: store)
        first.player.currentPanelHeight = 444
        let second = AppModel(backend: MockBackend(trackCount: 1), layoutStore: store)
        #expect(second.player.currentPanelHeight == 444)
        second.player.layout = .two
        second.player.currentPanelHeight = 555
        let third = AppModel(backend: MockBackend(trackCount: 1), layoutStore: store)
        #expect(third.player.layout == .two && third.player.currentPanelHeight == 555)
    }

    @Test func theInfoPanelBeingOpenSurvivesARelaunch() {
        let store = isolatedStore()
        let first = AppModel(backend: MockBackend(trackCount: 1), layoutStore: store)
        first.infoPanelOpen = true
        #expect(AppModel(backend: MockBackend(trackCount: 1), layoutStore: store).infoPanelOpen)
    }
}

// MARK: - Demo hooks

@Suite struct ChromeDemoGuardTests {
    private let roots = DeviceDemoGuard.temporaryRoots()

    @Test func aBackupHookNeedsAFixtureAndATemporaryFolder() {
        let env = ["RBXPORT_FIXTURE_DIR": "/tmp/fx"]
        #expect(ChromeDemoGuard.backupAllowed(environment: env, isFixture: true, backupDirectory: "/tmp/fx/backups", roots: roots))
        #expect(!ChromeDemoGuard.backupAllowed(environment: env, isFixture: false, backupDirectory: "/tmp/fx/backups", roots: roots))
        #expect(!ChromeDemoGuard.backupAllowed(environment: [:], isFixture: true, backupDirectory: "/tmp/fx/backups", roots: roots))
        #expect(!ChromeDemoGuard.backupAllowed(environment: env, isFixture: true, backupDirectory: "/Users/me/Library/backups", roots: roots))
        #expect(!ChromeDemoGuard.backupAllowed(environment: env, isFixture: true, backupDirectory: "/Volumes/Stick/b", roots: roots))
    }

    @Test func aNewLibraryHookNeedsBothPlacesToBeTemporary() {
        let ok = ["RBXPORT_OPTIONS": "/tmp/o/options.json", "RBXPORT_DEFAULT_LIBRARY_DIR": "/tmp/o/lib"]
        #expect(ChromeDemoGuard.newLibraryAllowed(environment: ok, roots: roots))
        #expect(!ChromeDemoGuard.newLibraryAllowed(environment: ["RBXPORT_OPTIONS": "/tmp/o/options.json"], roots: roots))
        #expect(!ChromeDemoGuard.newLibraryAllowed(environment: [:], roots: roots))
        var home = ok
        home["RBXPORT_DEFAULT_LIBRARY_DIR"] = "/Users/me/Library/Pioneer/rekordbox"
        #expect(!ChromeDemoGuard.newLibraryAllowed(environment: home, roots: roots))
    }
}

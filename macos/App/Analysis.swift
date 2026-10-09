import Foundation
import Observation

/// One track waiting to be analysed.
struct AnalysisItem: Equatable, Sendable {
    var id: String
    var title: String
}

struct AnalysisFailure: Equatable, Sendable {
    var id: String
    var title: String
    var reason: String
}

/// The analysis queue: tracks are analysed a few at a time, with progress for the status bar.
/// Ported from `lib/queue.ts` and `useAnalysis.ts`. Each analysis passes the core's write gate;
/// a refusal ends the run rather than failing every track the same way.
@MainActor @Observable
final class AnalysisQueue {
    /// How many tracks are analysed at once, 1 to 4 (3 by default). Persisted.
    static let slotChoices = [1, 2, 3, 4]
    static let defaultSlots = 3
    static let readOnlyMessage = "The library is read-only, so nothing can be analysed."

    private(set) var pending: [AnalysisItem] = []
    private(set) var running: [AnalysisItem] = []
    private(set) var done = 0
    private(set) var failed: [AnalysisFailure] = []
    private(set) var cancelling = false
    /// Why the run stopped early (the gate refused), if it did.
    private(set) var abortReason: String?

    var slots: Int {
        didSet {
            let clamped = min(max(slots, 1), 4)
            if clamped != slots { slots = clamped; return }
            if slots != oldValue { prefs.concurrentTracks = slots }
            pump()
        }
    }

    /// Settings are taken when a batch is queued; a later change does not alter it.
    @ObservationIgnored var settings = AnalysisSettings(bpmGrid: true, key: true, highPrecision: true, minBpm: 70, maxBpm: 180)
    /// Analysis › Analysis mode: rekordbox's settings instead of rbxport's.
    var rekordboxMode: Bool {
        get { prefs.analysisMode == .rekordbox }
        set { prefs.analysisMode = newValue ? .rekordbox : .rbxport }
    }
    /// Called for each track that finished.
    @ObservationIgnored var onAnalysed: ((AnalysisResult) -> Void)?
    /// Called once when a run is over, however it ended: the app reloads the library then.
    @ObservationIgnored var onDrained: (() -> Void)?

    @ObservationIgnored private let backend: any BackendProtocol
    @ObservationIgnored private let defaults: UserDefaults
    let prefs: PreferencesStore
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var runSettings: [String: (AnalysisSettings, Bool)] = [:]

    init(backend: any BackendProtocol, defaults: UserDefaults, prefs: PreferencesStore? = nil) {
        self.backend = backend
        self.defaults = defaults
        let prefs = prefs ?? PreferencesStore(defaults: defaults)
        self.prefs = prefs
        slots = min(max(prefs.concurrentTracks, 1), 4)
        prefs.onChange { [weak self] key in
            if key == PrefKeys.concurrentTracks, let self, self.slots != prefs.concurrentTracks { self.slots = prefs.concurrentTracks }
        }
    }

    var isActive: Bool { !pending.isEmpty || !running.isEmpty }
    var completed: Int { done + failed.count }
    var total: Int { completed + running.count + pending.count }
    var fraction: Double? { total > 0 ? Double(completed) / Double(total) : nil }

    /// "Analysing 3 of 10", or what a finished run left.
    var statusText: String? {
        guard total > 0 else { return nil }
        if isActive { return "Analysing \(min(completed + 1, total)) of \(total)\(cancelling ? " (stopping)" : "")" }
        var text = "Analysed \(done) of \(total)"
        if !failed.isEmpty { text += "; \(failed.count) failed" }
        return text + "."
    }

    /// Queues tracks, skipping any already pending or running. Returns how many were added.
    @discardableResult
    func enqueue(_ items: [AnalysisItem]) -> Int {
        if !isActive { reset() }
        let known = Set((pending + running).map(\.id))
        var seen = known
        let fresh = items.filter { seen.insert($0.id).inserted }
        for item in fresh { runSettings[item.id] = (settings, rekordboxMode) }
        pending += fresh
        cancelling = false
        pump()
        return fresh.count
    }

    /// Stops starting new tracks; those running finish.
    func cancel() {
        guard isActive else { return }
        cancelling = true
        pending.removeAll()
        finishIfDrained()
    }

    func reset() {
        guard !isActive else { return }
        done = 0
        failed = []
        cancelling = false
        abortReason = nil
    }

    /// Waits until the run is over. For tests.
    func waitUntilDrained() async {
        while isActive || !tasks.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func pump() {
        while !cancelling, running.count < slots, !pending.isEmpty {
            let item = pending.removeFirst()
            running.append(item)
            let (settings, rekordbox) = runSettings.removeValue(forKey: item.id) ?? (self.settings, rekordboxMode)
            let backend = backend
            tasks[item.id] = Task { [weak self] in
                let outcome: Result<AnalysisResult, Error>
                do {
                    outcome = .success(try await backend.analyseTrack(trackID: item.id, settings: settings, rekordboxMode: rekordbox))
                } catch {
                    outcome = .failure(error)
                }
                self?.finish(item, outcome)
            }
        }
    }

    private func finish(_ item: AnalysisItem, _ outcome: Result<AnalysisResult, Error>) {
        running.removeAll { $0.id == item.id }
        tasks[item.id] = nil
        switch outcome {
        case .success(let result):
            done += 1
            onAnalysed?(result)
        case .failure(let error):
            failed.append(AnalysisFailure(id: item.id, title: item.title, reason: describe(error)))
            // The gate refused: every track behind this one would be refused the same way.
            if case FfiError.ReadOnly(let message, _) = error {
                abortReason = message
                cancelling = true
                for rest in pending { failed.append(AnalysisFailure(id: rest.id, title: rest.title, reason: message)) }
                pending.removeAll()
            }
        }
        pump()
        finishIfDrained()
    }

    private func finishIfDrained() {
        guard pending.isEmpty, running.isEmpty else { return }
        cancelling = false
        onDrained?()
    }
}

// MARK: - The app's side

extension AppModel {
    /// Analyze Track(s): queues these tracks. Refused while the library cannot be written.
    func analyse(_ ids: [String]) {
        let tracks = ids.filter { !Self.isLoose($0) }
        guard !tracks.isEmpty else { return }
        guard canEdit else {
            notice = AnalysisQueue.readOnlyMessage
            return
        }
        let items = tracks.map { AnalysisItem(id: $0, title: loadedRow(id: $0)?.title ?? $0) }
        analysis.enqueue(items)
    }

    func analyseSelection() { analyse(orderedSelection) }

    /// Analysis Lock On or Off for the selected tracks, through the gate.
    func setAnalysisLock(_ on: Bool, ids: [String]) async {
        let backend = backend
        for id in ids where !Self.isLoose(id) {
            if await performEdit({ try await backend.gridLock(trackID: id, on: on) }) == nil { return }
        }
        notice = on ? "Analysis locked." : "Analysis unlocked."
    }

    func convertMemoryCuesToHot(ids: [String]) async {
        let backend = backend
        var made: UInt32 = 0
        for id in ids where !Self.isLoose(id) {
            guard let count = await performEdit({ try await backend.convertMemoryCuesToHot(trackID: id) }) else { return }
            made += count
        }
        notice = "Converted \(made) memory cue\(made == 1 ? "" : "s") to hot cues."
    }

    /// Library events that concern the decks, the table and the waveforms.
    func handleEditEvent(_ event: LibraryEvent) async {
        player.handle(libraryEvent: event)
        switch event {
        case .analysisChanged:
            // The overview and the Preview column draw from the analysis files.
            waveforms.removeAll()
            info.libraryChanged()
        case .cuesChanged(let id):
            // The Preview column and the hot cue letters follow the cues: read the rows again.
            if pager.containsLoadedRow(id: id) { reopen() }
        default:
            break
        }
    }
}

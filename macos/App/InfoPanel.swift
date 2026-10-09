import AppKit
import Observation
import SwiftUI

enum InfoTab: String, CaseIterable, Sendable {
    case summary, info, artwork

    var label: String {
        switch self {
        case .summary: L10n.t("Summary")
        case .info: "Info"
        case .artwork: L10n.t("Artwork")
        }
    }
}

/// The information panel's state: what it shows, and the fetches behind it.
///
/// The subject is the single selected track; with none or several selected the panel shows an
/// empty state. The record is fetched when the panel is open and the subject (or the library)
/// changes. Replies carry the request that asked for them: one that arrives after the subject
/// has moved on is dropped.
@MainActor @Observable
final class InfoPanelModel {
    enum Subject: Equatable, Sendable {
        case none
        case several(Int)
        case track(String)
    }

    private(set) var subject: Subject = .none
    /// The grid row for the subject, while its page is loaded (for the title before the record arrives).
    private(set) var row: Row?
    private(set) var details: TrackDetails?
    private(set) var lookups: TrackLookups?
    /// The artwork at up to 1024 px, for the Summary and Artwork tabs.
    private(set) var artwork: NSImage?
    private(set) var artworkFailed = false
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    var tab: InfoTab = .summary {
        didSet {
            if tab != oldValue { defaults.set(tab.rawValue, forKey: "infoPanel.tab") }
            if tab == .info { fetchLookupsIfNeeded() }
        }
    }
    /// The panel is open; nothing is fetched while it is closed.
    private(set) var isActive = false
    /// The write gate is open, so the Info tab shows editors instead of values.
    var editable = false
    /// Performs an edit on the track (the app model supplies it); true when it was written.
    @ObservationIgnored var onEdit: (InfoEdit, String) async -> Bool = { _, _ in false }

    /// Record fetches issued, for tests.
    private(set) var detailFetches = 0

    @ObservationIgnored private let backend: any BackendProtocol
    @ObservationIgnored private let artworkService: ArtworkService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var lookupsToken = 0
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTicket: ArtworkService.Ticket?

    init(backend: any BackendProtocol, artwork: ArtworkService, defaults: UserDefaults = .standard) {
        self.backend = backend
        artworkService = artwork
        self.defaults = defaults
        tab = defaults.string(forKey: "infoPanel.tab").flatMap(InfoTab.init) ?? .summary
    }

    /// My Tag names by id, for the Info tab.
    var myTagNames: [String: String] {
        var names: [String: String] = [:]
        for category in lookups?.myTagCategories ?? [] { for tag in category.tags { names[tag.id] = tag.name } }
        return names
    }

    // MARK: Inputs

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { reload(clearing: false) } else { cancelPending() }
    }

    /// The table's selection changed. `row` is the selected track's grid row when one is known.
    func selectionChanged(_ ids: Set<String>, row: Row?) {
        let next: Subject = ids.isEmpty ? .none : ids.count == 1 ? .track(ids.first ?? "") : .several(ids.count)
        self.row = row
        guard next != subject else { return }
        subject = next
        details = nil
        artwork = nil
        artworkFailed = false
        errorMessage = nil
        cancelPending()
        if isActive { reload(clearing: true) }
    }

    /// The library reloaded: the record may have changed. Re-fetch without blanking the panel.
    func libraryChanged() {
        lookups = nil
        guard isActive else { return }
        reload(clearing: false)
        if tab == .info { fetchLookupsIfNeeded() }
    }

    // MARK: Fetching

    private func cancelPending() {
        token += 1
        detailTask?.cancel()
        artworkService.cancel(artworkTicket)
        artworkTicket = nil
        isLoading = false
    }

    private func reload(clearing: Bool) {
        guard case .track(let id) = subject else {
            isLoading = false
            return
        }
        token += 1
        let mine = token
        detailTask?.cancel()
        isLoading = details == nil
        detailFetches += 1
        let backend = backend
        detailTask = Task { [weak self] in
            let result: Result<TrackDetails, Error>
            do { result = .success(try await backend.trackDetails(id: id)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            self.receive(result, for: id, token: mine)
        }
        if tab == .info { fetchLookupsIfNeeded() }
    }

    /// Takes a reply if it is still wanted: same request, same subject.
    func receive(_ result: Result<TrackDetails, Error>, for id: String, token mine: Int) {
        guard mine == token, subject == .track(id) else { return }
        isLoading = false
        switch result {
        case .success(let record):
            guard record.id == id else { return }
            details = record
            errorMessage = nil
            loadArtwork(for: record)
        case .failure(let error):
            details = nil
            errorMessage = describe(error)
        }
    }

    private func loadArtwork(for record: TrackDetails) {
        artworkService.cancel(artworkTicket)
        artworkTicket = nil
        guard record.hasArtwork else {
            artwork = nil
            artworkFailed = false
            return
        }
        let id = record.id
        let mine = token
        artworkTicket = artworkService.request(id: id, pixels: 1024) { [weak self] image in
            // A reply for a track that is no longer the subject is dropped.
            guard let self, mine == self.token, self.subject == .track(id) else { return }
            self.artwork = image
            self.artworkFailed = image == nil
        }
    }

    private func fetchLookupsIfNeeded() {
        guard isActive, lookups == nil, lookupTask == nil else { return }
        lookupsToken += 1
        let mine = lookupsToken
        let backend = backend
        lookupTask = Task { [weak self] in
            let loaded = try? await backend.trackLookups()
            guard let self else { return }
            self.lookupTask = nil
            if mine == self.lookupsToken { self.lookups = loaded }
        }
    }

    /// An edit made in the Info tab, on the panel's single subject. The record is re-read when
    /// the library changes; a refusal leaves the editors showing what is stored.
    @discardableResult
    func edit(_ change: InfoEdit) async -> Bool {
        guard case .track(let id) = subject else { return false }
        let done = await onEdit(change, id)
        if !done, isActive { reload(clearing: false) }
        return done
    }

    /// Waits for the record fetch in flight. For tests.
    func settle() async {
        await detailTask?.value
        await lookupTask?.value
    }
}

// MARK: - Views

struct InfoPanelView: View {
    let model: InfoPanelModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                ForEach(InfoTab.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            content
        }
        .frame(minWidth: 220, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("info-panel")
    }

    @ViewBuilder private var content: some View {
        switch model.subject {
        case .none:
            empty("No track selected", detail: "Select a track to see its information.")
        case .several(let count):
            empty("\(count) tracks selected", detail: "Select a single track to see its information.")
        case .track:
            if let message = model.errorMessage, model.details == nil {
                empty("Could not load the track", detail: message)
            } else {
                switch model.tab {
                case .summary: SummaryTab(model: model)
                case .info: InfoTabView(model: model)
                case .artwork: ArtworkTab(model: model)
                }
            }
        }
    }

    private func empty(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "info.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The sleeve, or a record tinted by the track's hue when there is none.
struct ArtworkImage: View {
    let model: InfoPanelModel
    var corner: CGFloat = 6

    var body: some View {
        ZStack {
            if let image = model.artwork {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if model.details?.hasArtwork == true && !model.artworkFailed {
                Rectangle().fill(.quaternary.opacity(0.5)).overlay(ProgressView().controlSize(.small))
            } else {
                RecordPlaceholderView(hue: Double(model.row?.artworkHue ?? 0))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: corner))
        .overlay(RoundedRectangle(cornerRadius: corner).stroke(.separator, lineWidth: 0.5))
        .accessibilityLabel("Artwork")
    }
}

struct SummaryTab: View {
    let model: InfoPanelModel

    private var title: String { model.details?.title ?? model.row?.title ?? "" }
    private var artist: String { model.details?.artist ?? model.row?.artist ?? "" }
    private var album: String { model.details?.album ?? model.row?.album ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ArtworkImage(model: model)
                    .frame(maxWidth: 260)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(3).textSelection(.enabled)
                    if !artist.isEmpty { Text(artist).font(.subheadline).textSelection(.enabled) }
                    if !album.isEmpty { Text(album).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Divider()
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                    ForEach(InfoFormat.summaryFacts(row: model.row, details: model.details), id: \.label) { fact in
                        GridRow {
                            Text(fact.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(fact.value).textSelection(.enabled).lineLimit(fact.label == L10n.t("Location") ? 4 : 1)
                                .truncationMode(fact.label == L10n.t("Location") ? .middle : .tail)
                        }
                    }
                }
                .font(.callout)
            }
            .padding(12)
        }
    }
}

struct InfoTabView: View {
    let model: InfoPanelModel

    var body: some View {
        if let details = model.details {
            if model.editable {
                InfoEditForm(model: model, details: details).id(details.id)
            } else {
                Form {
                    ForEach(InfoFormat.infoSections(details, myTagNames: model.myTagNames), id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.facts, id: \.label) { fact in
                                LabeledContent(fact.label) {
                                    Text(fact.value.isEmpty ? "\u{2014}" : fact.value)
                                        .foregroundStyle(fact.value.isEmpty ? .tertiary : .primary)
                                        .textSelection(.enabled).multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ArtworkTab: View {
    let model: InfoPanelModel

    var body: some View {
        ArtworkImage(model: model, corner: 4)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A record in a sleeve-sized square: the placeholder for tracks without artwork.
struct RecordPlaceholderView: View {
    let hue: Double

    var body: some View {
        GeometryReader { geometry in
            Image(nsImage: RecordArt.image(hue: hue, edge: max(geometry.size.width, 1)))
                .resizable().interpolation(.high)
        }
    }
}

/// The record drawn for a track without artwork, tinted by its hue.
enum RecordArt {
    /// A square image `edge` points across.
    static func image(hue degrees: Double, edge: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, rect: rect, hue: degrees)
            return true
        }
    }

    static func draw(in context: CGContext, rect: CGRect, hue degrees: Double) {
        let hue = CGFloat((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360)
        context.saveGState()
        defer { context.restoreGState() }
        // Ground tinted by the hue, a darker disc, grooves, and a label in the hue.
        let ground = NSColor(hue: hue, saturation: 0.35, brightness: 0.30, alpha: 1)
        context.setFillColor(ground.cgColor)
        context.fill(rect)
        let edge = min(rect.width, rect.height)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = edge * 0.46
        func circle(_ r: CGFloat) -> CGRect { CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2) }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fillEllipse(in: circle(radius))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
        context.setLineWidth(max(edge / 200, 0.5))
        var groove = radius * 0.93
        while groove > radius * 0.42 {
            context.strokeEllipse(in: circle(groove))
            groove -= radius * 0.07
        }
        context.setFillColor(NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).cgColor)
        context.fillEllipse(in: circle(radius * 0.32))
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fillEllipse(in: circle(max(radius * 0.045, 0.75)))
    }
}

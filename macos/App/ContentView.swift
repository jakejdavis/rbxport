import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        switch model.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Opening your rekordbox library...").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Could not open the library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Text("rbxport opens ~/Library/Pioneer/rekordbox read-only. Is rekordbox installed?")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .ready:
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240)
            } detail: {
                DetailView()
            }
            .sheet(item: $model.smartEditor) { editor in
                SmartEditorSheet(
                    editor: editor, save: { Task { await model.saveSmartEditor(editor) } },
                    cancel: { model.smartEditor = nil })
            }
            .sheet(item: $model.missingFiles) { missing in
                MissingFilesSheet(model: missing, editable: model.canEdit, close: { model.missingFiles = nil })
            }
            .sheet(item: $model.duplicates) { duplicates in
                DuplicatesSheet(model: duplicates, editable: model.canEdit, close: { model.duplicates = nil })
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Toggle(isOn: Binding(get: { model.filterBarOpen }, set: { model.filterBarOpen = $0 })) {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .help("Show the track filter")
                }
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Picker("Layout", selection: Binding(get: { model.player.layout }, set: { model.player.layout = $0 })) {
                            ForEach(PlayerLayout.allCases) { layout in
                                Text("\(layout.label)  \u{2318}\(String(layout.keyEquivalent))").tag(layout)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Layout", systemImage: "rectangle.split.1x2")
                    }
                    .help("Choose how many players are shown (\u{2318}7 to \u{2318}0)")
                }
                ToolbarItem(placement: .primaryAction) {
                    MasterLevelControl(master: model.player.master)
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: Binding(get: { model.infoPanelOpen }, set: { model.infoPanelOpen = $0 })) {
                        Label("Information", systemImage: "info.circle")
                    }
                    .help("Show the track information panel")
                }
                ToolbarItem(placement: .primaryAction) {
                    SearchFieldView(
                        model: model, query: model.query, scope: model.searchField,
                        focusRequests: model.searchFocusRequests
                    )
                    .frame(width: 240)
                }
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SidebarOutline(
            model: model, version: model.sidebar.version, selectedID: model.selectedNodeID,
            showCounts: model.sidebar.showChildCounts)
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    /// What the browser keeps under the player (table, filter bar, status line): the panel gives
    /// way before the window has to grow, or the window and its content chase each other.
    static let browserReserve = 170.0

    var body: some View {
        @Bindable var model = model
        // Not a VSplitView: an AppKit view inside its first pane (the detail waveform) sends the
        // split view's size constraints into an endless update. The divider is drawn here instead.
        GeometryReader { geometry in
        VStack(spacing: 0) {
            if model.player.layout != .browser {
                Group {
                    switch model.player.layout {
                    case .two:
                        DualDeckPanel(player: model.player, palette: model.waveformPalette)
                    case .simple:
                        SimplePlayerPanel(player: model.player, deck: model.player.deckA, palette: model.waveformPalette)
                    case .one, .browser:
                        DeckPanel(deck: model.player.deckA, player: model.player, palette: model.waveformPalette)
                    }
                }
                .frame(height: min(model.player.currentPanelHeight, max(geometry.size.height - Self.browserReserve, 120)))
                PanelDivider(player: model.player)
            }
            VStack(spacing: 0) {
                if model.filterBarOpen {
                    FilterBar(model: model)
                    Divider()
                }
                if let opened = model.opened {
                    TrackTable(
                        model: model, opened: opened, layout: model.layout, keyStyle: model.keyStyle,
                        sortKey: model.sortKey, descending: model.descending,
                        palette: model.waveformPalette, rowHeight: model.rowHeight)
                } else {
                    Spacer()
                }
                Divider()
                StatusLine()
            }
            .frame(minHeight: 120)
        }
        }
        .inspector(isPresented: $model.infoPanelOpen) {
            InfoPanelView(model: model.info)
                .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
        }
        .overlay(alignment: .top) {
            if let error = model.viewError {
                Text(error).padding(8).background(.red.opacity(0.2), in: .rect(cornerRadius: 6)).padding()
            }
        }
    }
}

struct StatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            if let s = model.summary {
                Text("\(s.trackCount) tracks")
                Text("\(s.playlistCount) playlists")
                Text(s.readOnly ? "Read-only" : "Read-write")
                Text("Loaded in \(s.loadMs) ms")
            }
            if let progress = model.importProgress {
                ImportProgressView(progress: progress)
            }
            if model.analysis.statusText != nil {
                AnalysisStatusView(queue: model.analysis)
            }
            Spacer()
            if let notice = model.notice {
                Text(notice).foregroundStyle(.primary)
                Button("Dismiss", systemImage: "xmark.circle.fill") { model.dismissNotice() }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
            }
            if let summary = model.selectionSummary {
                Text(summary.text)
            }
            if let opened = model.opened {
                Text("Showing \(opened.handle.len)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}


/// The draggable edge under the deck panel.
struct PanelDivider: View {
    let player: PlayerModel
    @State private var startHeight: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .overlay {
                Color.clear.frame(height: 9).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startHeight ?? player.currentPanelHeight
                                startHeight = start
                                player.currentPanelHeight = start + value.translation.height
                            }
                            .onEnded { _ in startHeight = nil })
            }
            .accessibilityLabel("Player size")
    }
}

/// The master level in the toolbar: 0 to 10 on the taper, 11 past the notch.
struct MasterLevelControl: View {
    let master: MasterModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { master.reading }, set: { master.setReading($0) }), in: 0...MasterScale.full
            )
            .frame(width: 84)
            .controlSize(.small)
            Text(MasterScale.label(master.reading))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
        }
        .help("Master level (10 is the default, 11 is +2 dB)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Master level")
    }
}

/// The status bar's import progress: a bar and what is being read.
struct ImportProgressView: View {
    let progress: ImportProgressState

    var body: some View {
        HStack(spacing: 6) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction).frame(width: 90)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(progress.text).lineLimit(1).truncationMode(.middle).frame(maxWidth: 320, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("import-progress")
    }
}


/// The analysis queue in the status bar: progress, Stop while it runs, the failures after.
struct AnalysisStatusView: View {
    let queue: AnalysisQueue

    var body: some View {
        HStack(spacing: 6) {
            if queue.isActive, let fraction = queue.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 90)
            }
            Text(queue.statusText ?? "")
            if queue.isActive {
                Button("Stop", systemImage: "stop.circle") { queue.cancel() }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .help("Stop analysing after the tracks in progress")
            } else {
                Button("Dismiss", systemImage: "xmark.circle.fill") { queue.reset() }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
            }
        }
        .help(queue.failed.isEmpty ? "Analysis" : queue.failed.prefix(8).map { "\($0.title): \($0.reason)" }.joined(separator: "\n"))
        .accessibilityLabel(queue.statusText ?? "Analysis")
    }
}

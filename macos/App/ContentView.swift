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
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Toggle(isOn: Binding(get: { model.filterBarOpen }, set: { model.filterBarOpen = $0 })) {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .help("Show the track filter")
                }
                ToolbarItem(placement: .navigation) {
                    Toggle(isOn: Binding(get: { model.player.panelOpen }, set: { model.player.panelOpen = $0 })) {
                        Label("Player", systemImage: "waveform")
                    }
                    .help("Show the player")
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

    var body: some View {
        @Bindable var model = model
        // Not a VSplitView: an AppKit view inside its first pane (the detail waveform) sends the
        // split view's size constraints into an endless update. The divider is drawn here instead.
        VStack(spacing: 0) {
            if model.player.panelOpen {
                DeckPanel(deck: model.player.deckA, player: model.player, palette: model.waveformPalette)
                    .frame(height: model.player.panelHeight)
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
                                let start = startHeight ?? player.panelHeight
                                startHeight = start
                                player.panelHeight = min(max(start + value.translation.height, PlayerModel.panelHeightRange.lowerBound), PlayerModel.panelHeightRange.upperBound)
                            }
                            .onEnded { _ in startHeight = nil })
            }
            .accessibilityLabel("Player size")
    }
}

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
            .searchable(text: $model.query, placement: .toolbar, prompt: "Search")
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(model.tree, children: \.children, selection: $model.selection) { item in
            Label(item.node.name, systemImage: item.symbol)
                .badge(item.node.childCount.map { Int($0) } ?? 0)
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let opened = model.opened {
                TrackTable(
                    backend: model.backend,
                    opened: opened,
                    onSort: { key, descending in model.sort(by: key, descending: descending) }
                )
            } else {
                Spacer()
            }
            Divider()
            StatusLine()
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
            if let opened = model.opened {
                Text("Showing \(opened.handle.len)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}

import AppKit
import SwiftUI

// MARK: - Strip

/// The Pro DJ LINK strip along the bottom of the browser (`LinkDeckStrip.tsx`): the LINK button, the
/// master clock and the players. Off, it is the LINK button alone; on, the decks sit beside it with the
/// mixer between them. It draws only what the link reports: a loaded track, play state and master.
struct LinkDeckStrip: View {
    let model: LinkModel
    @State private var explaining = false

    var body: some View {
        if model.stripVisible {
            HStack(spacing: 10) {
                linkButton
                if model.isBlocked {
                    Button("unavailable") { explaining.toggle() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("link-unavailable")
                }
                if model.isOn, let status = model.status {
                    MasterClock(model: model, status: status)
                    let seats = model.seating
                    HStack(spacing: 6) {
                        ForEach(seats.left, id: \.number) { DeckTile(model: model, player: $0) }
                        ForEach(seats.mixers, id: \.number) { MixerTile(device: $0) }
                        ForEach(seats.right, id: \.number) { DeckTile(model: model, player: $0) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Players on the link")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(model.isOn ? Color.accentColor.opacity(0.07) : Color.clear)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("link-deck-strip")
            Divider()
        }
    }

    private var linkButton: some View {
        Button {
            if model.isBlocked { explaining.toggle() } else { Task { await model.toggle() } }
        } label: {
            Label("LINK", systemImage: model.isOn ? "link.circle.fill" : "link")
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.isOn ? Color.accentColor : .secondary)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(model.busy)
        .help(model.buttonHelp)
        .accessibilityIdentifier("link-button")
        .accessibilityValue(model.isBlocked ? "unavailable" : model.isOn ? "on" : "off")
        .popover(isPresented: $explaining, arrowEdge: .top) {
            Text(model.status?.problem ?? "")
                .font(.callout).padding(12).frame(maxWidth: 320, alignment: .leading)
                .accessibilityLabel("Why PRO DJ LINK is unavailable")
        }
    }
}

/// The tempo master clock: the BPM with minus and plus, the MASTER toggle, and take-the-master's-tempo.
private struct MasterClock: View {
    let model: LinkModel
    let status: LinkStatus

    var body: some View {
        HStack(spacing: 6) {
            Text(String(format: "%.2f", status.masterBpm))
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(status.master ? Color.orange : .secondary)
                .frame(minWidth: 56, alignment: .trailing)
                .accessibilityLabel("Master tempo")
            Button { Task { await model.nudge(-1) } } label: { Image(systemName: "minus") }
                .help("Nudge the master tempo down 1 BPM.").accessibilityLabel("Master tempo down")
                .accessibilityIdentifier("link-nudge-down")
            Button { Task { await model.nudge(1) } } label: { Image(systemName: "plus") }
                .help("Nudge the master tempo up 1 BPM.").accessibilityLabel("Master tempo up")
                .accessibilityIdentifier("link-nudge-up")
            Toggle("MASTER", isOn: Binding(get: { status.master }, set: { on in Task { await model.setMaster(on) } }))
                .toggleStyle(.button).font(.caption.weight(.bold)).tint(.orange)
                .help(
                    status.master
                        ? "This computer is the tempo master. Click to resign."
                        : "Make this computer the tempo master; players set to SYNC follow this tempo."
                )
                .accessibilityIdentifier("link-master")
            Button { Task { await model.takeMasterTempo() } } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .disabled(!model.canTakeTempo)
                .help(
                    model.canTakeTempo
                        ? "Take the current master player's tempo as the master tempo."
                        : "No player is master, so there is no tempo to take."
                )
                .accessibilityLabel("Take the master player's tempo")
                .accessibilityIdentifier("link-take-tempo")
        }
        .controlSize(.small)
    }
}

/// One player: its number, PLAY or CUE, MASTER and SYNC lamps, and the loaded title and artist.
/// While a library track is dragged over it, it takes the drop and tells the CDJ to load it.
private struct DeckTile: View {
    let model: LinkModel
    let player: LinkPlayer
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(player.number)").font(.caption.weight(.bold))
                Text(player.playing ? "PLAY" : player.cued ? "CUE" : " ")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(player.playing ? Color.green : .orange)
                    .frame(minWidth: 24, alignment: .leading)
                lamp("MASTER", on: player.master, colour: .orange)
                lamp("SYNC", on: player.sync, colour: .blue)
            }
            if let loaded = player.loaded {
                Text(loaded.title.isEmpty ? "Track \(loaded.id)" : loaded.title)
                    .font(.caption).lineLimit(1).truncationMode(.tail)
                if !loaded.artist.isEmpty {
                    Text(loaded.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(targeted ? "Drop to load" : "No track").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(width: 150, height: 46, alignment: .topLeading)
        .background(.quaternary.opacity(player.playing ? 0.9 : 0.4), in: .rect(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(targeted ? Color.accentColor : player.master ? Color.orange.opacity(0.7) : .clear, lineWidth: targeted ? 2 : 1)
        }
        .overlay { LinkDropTarget(isTargeted: $targeted) { ids in Task { await model.drop(trackIDs: ids, onPlayer: player.number) } } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Player \(player.number)")
        .accessibilityValue(deckSummary)
        .accessibilityIdentifier("link-player-\(player.number)")
    }

    private var deckSummary: String {
        var parts: [String] = []
        if player.master { parts.append("master") }
        if player.playing { parts.append("playing") }
        if let loaded = player.loaded { parts.append("loaded \(loaded.title)") }
        return parts.joined(separator: ", ")
    }

    private func lamp(_ text: String, on: Bool, colour: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .bold)).foregroundStyle(on ? colour : Color.secondary.opacity(0.35))
    }
}

private struct MixerTile: View {
    let device: LinkPlayer

    var body: some View {
        VStack(spacing: 2) {
            Text(device.kind == .mixer ? "MIXER" : device.name).font(.caption.weight(.semibold))
            Text("MASTER").font(.system(size: 9, weight: .bold))
                .foregroundStyle(device.master ? Color.orange : Color.secondary.opacity(0.35))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(minWidth: 64, minHeight: 46, maxHeight: 46)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mixer \(device.number)")
    }
}

/// A transparent AppKit drop target for dragged library tracks (`com.rbxport.export-track-ids`), which
/// every track drag carries whether or not the library may be edited.
private struct LinkDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: ([String]) -> Void

    func makeNSView(context: Context) -> TargetView {
        let view = TargetView()
        view.registerForDraggedTypes([.rbxportExportTracks])
        return view
    }

    func updateNSView(_ view: TargetView, context: Context) {
        view.onTarget = { targeted in DispatchQueue.main.async { isTargeted = targeted } }
        view.onDrop = onDrop
    }

    final class TargetView: NSView {
        var onTarget: (Bool) -> Void = { _ in }
        var onDrop: ([String]) -> Void = { _ in }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard !NSPasteboard.PasteboardType.exportTrackIDs(from: sender.draggingPasteboard).isEmpty else { return [] }
            onTarget(true)
            return .copy
        }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            NSPasteboard.PasteboardType.exportTrackIDs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
        }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) { onTarget(false) }
        override func draggingEnded(_ sender: any NSDraggingInfo) { onTarget(false) }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            onTarget(false)
            let ids = NSPasteboard.PasteboardType.exportTrackIDs(from: sender.draggingPasteboard)
            guard !ids.isEmpty else { return false }
            onDrop(ids)
            return true
        }
    }
}

// MARK: - Settings pane

/// Settings, PRO DJ LINK (`LinkPane.tsx`): the connection, auto-join, key sorting, the network
/// interface and the devices on the link.
struct LinkPane: View {
    let model: LinkModel

    var body: some View {
        Form {
            Section("PRO DJ LINK") {
                if let problem = model.problem {
                    Text(problem).foregroundStyle(.red).font(.callout)
                        .accessibilityIdentifier("link-problem")
                }
                LabeledContent {
                    // A refusal cannot be cleared by pressing the button again; the reason says what to do.
                    if !(model.isBlocked && !model.isOn) {
                        Button(model.busy ? "Please wait\u{2026}" : model.isOn ? "Disconnect" : "Connect to PRO DJ LINK") {
                            Task { await model.toggle() }
                        }
                        .disabled(model.busy || model.status == nil)
                        .accessibilityIdentifier("link-connect")
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.statusLabel).font(.headline).accessibilityIdentifier("link-status")
                        Text(summaryLine).font(.caption).foregroundStyle(.secondary)
                        if model.isOn, model.status?.state == .up {
                            Text("On your player, open LINK and select rekordbox.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("Auto-join LINK when available", isOn: Binding(get: { model.autoJoin }, set: { model.autoJoin = $0 }))
                    .accessibilityIdentifier("link-auto-join")
                Text("Turn on PRO DJ LINK automatically when a player or mixer is detected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Key sorting") {
                Picker("Key sorting", selection: Binding(get: { model.keySort }, set: { model.keySort = $0 })) {
                    Text("Musically \u{2014} Abm, B, Ebm, F#, Bbm, \u{2026}").tag(LinkKeySort.musical)
                    Text("Alphabetically \u{2014} A, Ab, B, \u{2026}").tag(LinkKeySort.alphabetical)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                .disabled(model.isOn)
                .accessibilityIdentifier("link-key-sort")
                Text("Applies to the key menu and tracks sorted by key on connected players. Disconnect to change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Network interface") {
                Text(model.isOn
                    ? "Disconnect to change the network interface."
                    : "Choose the network your players are connected to. Wired Ethernet is recommended.")
                    .font(.caption).foregroundStyle(.secondary)
                interfaceTable
            }
            if usesWifi {
                Section {
                    Label {
                        Text("PRO DJ LINK is not designed to work over Wi-Fi. Use a wired Ethernet connection for reliable playback.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .accessibilityIdentifier("link-wifi-warning")
                }
            }
            Section("Devices on your network (\(model.isOn ? model.players.count : 0))") { devices }
        }
        .formStyle(.grouped)
        .task {
            // Event-driven while open, with a slow poll for what produces no event: rekordbox
            // starting or quitting changes why LINK is off.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var summaryLine: String {
        if model.isOn, let interface = model.status?.interface { return "Using \(interface.name) \u{00B7} \(interface.address)" }
        return "Share your library with players on your network."
    }

    private var interfaces: [LinkInterface] { model.status?.interfaces ?? [] }
    private var canChoose: Bool { model.status != nil && !model.isOn && !model.busy }

    /// A selected or active Wi-Fi interface gets the warning.
    private var usesWifi: Bool {
        if let chosen = model.interface, let match = interfaces.first(where: { $0.name == chosen }) {
            return match.connection == .wireless
        }
        guard model.interface == nil, model.isOn, let active = model.status?.interface else { return false }
        return active.connection == .wireless || interfaces.contains { $0.name == active.name && $0.connection == .wireless }
    }

    private var interfaceTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(name: "Automatic", detail: "Let the app choose the interface", selected: model.interface == nil, badge: nil) {
                model.interface = nil
            }
            ForEach(interfaces, id: \.name) { item in
                let inUse = model.isOn && model.status?.interface?.name == item.name && model.status?.interface?.address == item.address
                row(
                    name: item.name,
                    detail: "\(Self.connection(item.connection))\(item.connection == .wired ? " (Recommended)" : "") \u{00B7} \(item.adapter ?? "Unknown") \u{00B7} \(item.address)",
                    selected: model.interface == item.name, badge: inUse ? "In use" : nil
                ) { model.interface = item.name }
            }
            if let saved = model.interface, !interfaces.contains(where: { $0.name == saved }) {
                row(name: saved, detail: "Not present", selected: true, badge: nil) {}
            }
        }
        .disabled(!canChoose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Network interfaces")
    }

    static func connection(_ connection: LinkConnection?) -> String {
        switch connection {
        case .wireless: "Wi-Fi"
        case .wired: "Wired"
        case nil: "Unknown"
        }
    }

    private func row(name: String, detail: String, selected: Bool, badge: String?, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(name).fontWeight(.medium)
                if let badge { Text(badge).font(.caption2.weight(.semibold)).padding(.horizontal, 5).background(.green.opacity(0.25), in: .capsule) }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var devices: some View {
        if model.isOn, !model.players.isEmpty {
            ForEach(model.players, id: \.number) { player in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.name).fontWeight(.medium)
                        if let loaded = player.loaded {
                            Text(loaded.artist.isEmpty ? loaded.title : "\(loaded.title) \u{00B7} \(loaded.artist)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text("\(Self.role(player)) \u{00B7} \(player.address)").font(.caption).foregroundStyle(.secondary)
                    Text(Self.deviceStatus(player)).font(.caption)
                    if player.master {
                        Text("Master").font(.caption2.weight(.semibold)).padding(.horizontal, 5)
                            .background(.orange.opacity(0.25), in: .capsule)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isOn ? "No devices found yet" : "Discover your devices").fontWeight(.medium)
                Text(
                    model.isOn
                        ? "Turn on your players and mixers, then connect them to the network shown above."
                        : "Choose a network interface and connect to see your players and mixers here."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func role(_ player: LinkPlayer) -> String {
        let kind: String =
            switch player.kind {
            case .player: "player"
            case .mixer: "mixer"
            case .rekordbox: "rekordbox"
            case .device: "device"
            }
        return "\(kind) \(player.number)"
    }

    static func deviceStatus(_ player: LinkPlayer) -> String {
        player.loaded != nil ? (player.playing ? "Playing" : "Loaded") : "Online"
    }
}

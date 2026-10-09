import Foundation
import Observation
import SwiftUI

// MARK: - Category and Sort list rules

/// The Category and Sort tabs' list logic, ported from `src/lib/deviceSettings.ts`. A row is
/// visible with a 1-based `seq` among the visible rows, or hidden with `seq` 0. The Active list
/// is the visible rows in `seq` order; the Inactive list is the rest, alphabetical.
enum DeviceSlots {
    enum Kind { case category, sort }

    /// `menuItem` ids as `exportLibrary.db` numbers them.
    enum Item {
        static let track: Int64 = 4
        static let playlist: Int64 = 17
        static let history: Int64 = 19
        static let search: Int64 = 20
        static let folder: Int64 = 24
        static let `default`: Int64 = 25
        static let alphabet: Int64 = 26
    }

    private static let fixedCategories: Set<Int64> = [Item.track, Item.playlist, Item.history, Item.search, Item.folder]
    private static let fixedSorts: Set<Int64> = [Item.default, Item.alphabet]

    /// Greyed in rekordbox and never moved.
    static func isFixed(_ kind: Kind, _ menuItem: Int64) -> Bool {
        (kind == .category ? fixedCategories : fixedSorts).contains(menuItem)
    }

    static func displayName(_ slot: MenuSlot) -> String {
        slot.menuItem == Item.alphabet ? "ALPHABET/TRACK NAME" : slot.name
    }

    static func active(_ slots: [MenuSlot]) -> [MenuSlot] { slots.filter(\.visible).sorted { $0.seq < $1.seq } }

    static func inactive(_ slots: [MenuSlot]) -> [MenuSlot] {
        slots.filter { !$0.visible }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func renumber(_ slots: [MenuSlot], order: [Int64]) -> [MenuSlot] {
        var position: [Int64: Int64] = [:]
        for (index, id) in order.enumerated() { position[id] = Int64(index + 1) }
        return slots.map { slot in
            var next = slot
            if let seq = position[slot.id] {
                next.visible = true
                next.seq = seq
            } else {
                next.visible = false
                next.seq = 0
            }
            return next
        }
    }

    /// Moves a hidden row to the end of the Active list.
    static func activate(_ slots: [MenuSlot], id: Int64) -> [MenuSlot] {
        guard let target = slots.first(where: { $0.id == id }), !target.visible else { return slots }
        return renumber(slots, order: active(slots).map(\.id) + [id])
    }

    /// Takes a visible row out of the Active list; the rest close up. Fixed rows stay.
    static func deactivate(_ kind: Kind, _ slots: [MenuSlot], id: Int64) -> [MenuSlot] {
        guard let target = slots.first(where: { $0.id == id }), target.visible, !isFixed(kind, target.menuItem) else { return slots }
        return renumber(slots, order: active(slots).map(\.id).filter { $0 != id })
    }

    /// Swaps a visible row with its neighbour above (`-1`) or below (`+1`).
    static func shift(_ slots: [MenuSlot], id: Int64, by step: Int) -> [MenuSlot] {
        var order = active(slots).map(\.id)
        guard let at = order.firstIndex(of: id) else { return slots }
        let to = at + step
        guard order.indices.contains(to) else { return slots }
        order.swapAt(at, to)
        return renumber(slots, order: order)
    }
}

// MARK: - The panel's model

/// A selected device's settings, as the stick holds them. Every change is written at once and the
/// panel shows what came back, so a write that did not take cannot leave the panel claiming it did.
@MainActor @Observable
final class DeviceSettingsModel {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case category = "Category"
        case sort = "Sort"
        case column = "Column"
        case color = "Color"
        var id: String { rawValue }
    }

    let path: String
    private let backend: any BackendProtocol
    var tab: Tab = .general
    private(set) var settings: DeviceSettings?
    private(set) var error: String?
    /// The row picked in the Category or Sort tab (one pick across both lists).
    var pickedSlot: Int64?
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var loadToken = 0

    init(path: String, backend: any BackendProtocol) {
        self.path = path
        self.backend = backend
    }

    /// Reads the stick. Called when the panel opens and after an export wrote to it.
    func load() async {
        loadToken += 1
        let token = loadToken
        do {
            let read = try await backend.deviceSettings(path: path)
            guard token == loadToken else { return }
            settings = read
            error = nil
        } catch {
            guard token == loadToken else { return }
            self.error = describe(error)
        }
    }

    /// Applies a change: shown at once, written, then replaced by what the stick now holds.
    /// Writes run one after another so a quick second change cannot overtake the first.
    func change(_ edit: (inout DeviceSettings) -> Void) async {
        guard var next = settings else { return }
        edit(&next)
        guard next != settings else { return }
        settings = next
        let previous = saveChain
        let backend = backend
        let path = path
        let write = Task { @MainActor [weak self] in
            await previous?.value
            do {
                let stored = try await backend.saveDeviceSettings(path: path, settings: next)
                self?.settings = stored
                self?.error = nil
            } catch {
                // Show what the stick holds, and why the change did not take.
                await self?.load()
                self?.error = describe(error)
            }
        }
        saveChain = write
        await write.value
    }

    /// Waits for pending writes. For tests.
    func settle() async { await saveChain?.value }

    // MARK: Tab-specific edits

    func setWaveformColor(_ value: WaveformColor) async { await change { $0.waveformColor = value } }
    func setWaveformPosition(_ value: WaveformPosition) async { await change { $0.waveformPosition = value } }
    func setKeyDisplay(_ value: KeyDisplay) async { await change { $0.keyDisplay = value } }

    /// The device name is committed on Return or when focus leaves, not per keystroke. An empty
    /// name keeps the old one.
    func commitName(_ draft: String) async {
        let trimmed = String(draft.trimmingCharacters(in: .whitespaces).prefix(64))
        guard !trimmed.isEmpty, trimmed != settings?.deviceName else { return }
        await change { $0.deviceName = trimmed }
    }

    func renameColor(id: Int64, to name: String) async {
        let trimmed = String(name.trimmingCharacters(in: .whitespaces).prefix(64))
        guard !trimmed.isEmpty else { return }
        await change { settings in
            if let index = settings.colors.firstIndex(where: { $0.id == id }) { settings.colors[index].name = trimmed }
        }
    }

    func setSubColumn(_ menuItem: Int64?) async { await change { $0.subColumn = menuItem } }

    private func slots(_ kind: DeviceSlots.Kind) -> [MenuSlot] {
        (kind == .category ? settings?.categories : settings?.sorts) ?? []
    }

    private func edit(_ kind: DeviceSlots.Kind, _ transform: ([MenuSlot]) -> [MenuSlot]) async {
        await change { settings in
            switch kind {
            case .category: settings.categories = transform(settings.categories)
            case .sort: settings.sorts = transform(settings.sorts)
            }
        }
    }

    func activate(_ kind: DeviceSlots.Kind) async {
        guard let id = pickedSlot else { return }
        await edit(kind) { DeviceSlots.activate($0, id: id) }
    }

    func deactivate(_ kind: DeviceSlots.Kind) async {
        guard let id = pickedSlot else { return }
        await edit(kind) { DeviceSlots.deactivate(kind, $0, id: id) }
    }

    func shift(_ kind: DeviceSlots.Kind, by step: Int) async {
        guard let id = pickedSlot else { return }
        await edit(kind) { DeviceSlots.shift($0, id: id, by: step) }
    }

    /// Which arrows the picked row allows.
    func canActivate(_ kind: DeviceSlots.Kind) -> Bool {
        guard settings?.hasLibrarySettings == true, let picked = slot(pickedSlot, kind) else { return false }
        return !picked.visible
    }

    func canDeactivate(_ kind: DeviceSlots.Kind) -> Bool {
        guard settings?.hasLibrarySettings == true, let picked = slot(pickedSlot, kind) else { return false }
        return picked.visible && !DeviceSlots.isFixed(kind, picked.menuItem)
    }

    func canShift(_ kind: DeviceSlots.Kind, by step: Int) -> Bool {
        guard settings?.hasLibrarySettings == true, let picked = slot(pickedSlot, kind), picked.visible else { return false }
        let active = DeviceSlots.active(slots(kind))
        guard let at = active.firstIndex(where: { $0.id == picked.id }) else { return false }
        return active.indices.contains(at + step)
    }

    private func slot(_ id: Int64?, _ kind: DeviceSlots.Kind) -> MenuSlot? {
        guard let id else { return nil }
        return slots(kind).first { $0.id == id }
    }
}

// MARK: - Views

/// The detail pane a selected device opens: five tabs over the stick's own settings.
struct DevicePanelView: View {
    let device: Device
    let model: DeviceSettingsModel
    let playlists: [PlaylistTarget]
    let exportPlaylist: (String) -> Void
    var importFromDevice: () -> Void = {}
    let busy: Bool

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: Bindable(model).tab) {
                ForEach(DeviceSettingsModel.Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            .accessibilityIdentifier("device-tabs")
            Divider()
            if let settings = model.settings {
                ScrollView {
                    Group {
                        switch model.tab {
                        case .general:
                            GeneralTabView(
                                device: device, settings: settings, model: model, playlists: playlists,
                                exportPlaylist: exportPlaylist, importFromDevice: importFromDevice, busy: busy)
                        case .category: ListPairView(kind: .category, settings: settings, model: model)
                        case .sort: ListPairView(kind: .sort, settings: settings, model: model)
                        case .column: ColumnTabView(settings: settings, model: model)
                        case .color: ColorTabView(settings: settings, model: model)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let error = model.error {
                ContentUnavailableView("Could not read the device", systemImage: "externaldrive.badge.exclamationmark", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = model.error, model.settings != nil {
                Divider()
                Text(error).font(.caption).foregroundStyle(.red).padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Device \(device.name)")
    }
}

private struct GeneralTabView: View {
    let device: Device
    let settings: DeviceSettings
    let model: DeviceSettingsModel
    let playlists: [PlaylistTarget]
    let exportPlaylist: (String) -> Void
    let importFromDevice: () -> Void
    let busy: Bool
    @State private var name = ""
    @State private var chosen: String?
    @FocusState private var nameFocused: Bool

    private var libraries: String {
        [settings.hasDeviceLibrary ? L10n.t("Device Library") : nil, settings.hasOneLibrary ? L10n.t("OneLibrary") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        Form {
            TextField("Device Name", text: $name)
                .focused($nameFocused)
                .disabled(!settings.hasLibrarySettings)
                .onSubmit { Task { await model.commitName(name) } }
                .onChange(of: nameFocused) { _, focused in if !focused { Task { await model.commitName(name) } } }
                .help(settings.hasLibrarySettings ? "" : "This device has no library to hold a name; export something to it first.")
            Picker(
                "Waveform color",
                selection: Binding(get: { settings.waveformColor }, set: { value in Task { await model.setWaveformColor(value) } })
            ) {
                Text("Blue").tag(WaveformColor.blue)
                Text("RGB").tag(WaveformColor.rgb)
                Text("3Band").tag(WaveformColor.threeBand)
            }
            .pickerStyle(.radioGroup)
            Picker(
                "Waveform position",
                selection: Binding(get: { settings.waveformPosition }, set: { value in Task { await model.setWaveformPosition(value) } })
            ) {
                Text("Left").tag(WaveformPosition.left)
                Text("Center").tag(WaveformPosition.center)
            }
            .pickerStyle(.radioGroup)
            Picker("Overview waveform", selection: .constant(settings.overviewWaveform)) {
                Text("Half Waveform").tag(StickOverview.half)
                Text("Full Waveform").tag(StickOverview.full)
            }
            .pickerStyle(.radioGroup)
            .disabled(true)
            .help("Shown as the stick has it; rekordbox does not offer it here either.")
            Picker(
                "Key display format",
                selection: Binding(get: { settings.keyDisplay }, set: { value in Task { await model.setKeyDisplay(value) } })
            ) {
                Text("Classic").tag(KeyDisplay.classic)
                Text("Alphanumeric").tag(KeyDisplay.alphanumeric)
            }
            .pickerStyle(.radioGroup)
            if !settings.hasDevSetting {
                Text("This stick has no DEVSETTING.DAT. Changing a display option creates it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Total Space", value: device.totalBytes > 0 ? CellFormat.bytes(device.totalBytes) : L10n.t("Unknown"))
                LabeledContent("Available Space", value: device.totalBytes > 0 ? CellFormat.bytes(device.freeBytes) : L10n.t("Unknown"))
                LabeledContent("Libraries", value: libraries.isEmpty ? "None" : libraries)
                LabeledContent("File system", value: device.fileSystem.isEmpty ? L10n.t("Unknown") : device.fileSystem)
                LabeledContent("Contents", value: device.contentsText)
            }
            if device.hasUnusualFileSystem {
                Label("Pioneer DJ recommends FAT32 for players.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Section("Export") {
                HStack {
                    Picker("Playlist", selection: Binding(get: { chosen ?? playlists.first?.id ?? "" }, set: { chosen = $0 })) {
                        ForEach(playlists, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    Button(busy ? "Exporting\u{2026}" : L10n.t("Export")) {
                        if let id = chosen ?? playlists.first?.id { exportPlaylist(id) }
                    }
                    .disabled(busy || playlists.isEmpty)
                    .accessibilityIdentifier("device-export-button")
                }
            }
            Section("Import") {
                HStack {
                    Text("Bring cues, play history or settings from this device back into the library.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import from Device\u{2026}", action: importFromDevice)
                        .disabled(busy)
                        .accessibilityIdentifier("device-import-button")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { name = settings.deviceName }
        .onChange(of: settings.deviceName) { _, new in if !nameFocused { name = new } }
    }
}

private struct ListPairView: View {
    let kind: DeviceSlots.Kind
    let settings: DeviceSettings
    let model: DeviceSettingsModel

    private var slots: [MenuSlot] { kind == .category ? settings.categories : settings.sorts }
    private var disabled: Bool { !settings.hasLibrarySettings }
    private var headings: (inactive: String, active: String) {
        kind == .category ? ("Inactive Categories", "Active Categories") : ("Inactive Sort Options", "Active Sort Options")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if disabled {
                Text("This device has no library to hold these; export something to it first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                list(headings.inactive, DeviceSlots.inactive(slots))
                VStack(spacing: 8) {
                    Button { Task { await model.activate(kind) } } label: { Image(systemName: "chevron.right") }
                        .disabled(!model.canActivate(kind)).help("Add to active")
                    Button { Task { await model.deactivate(kind) } } label: { Image(systemName: "chevron.left") }
                        .disabled(!model.canDeactivate(kind)).help("Remove from active")
                }
                .padding(.top, 60)
                VStack(alignment: .leading, spacing: 6) {
                    list(headings.active, DeviceSlots.active(slots))
                    HStack {
                        Button("Up") { Task { await model.shift(kind, by: -1) } }.disabled(!model.canShift(kind, by: -1))
                        Button("Down") { Task { await model.shift(kind, by: 1) } }.disabled(!model.canShift(kind, by: 1))
                    }
                }
            }
        }
    }

    private func list(_ title: String, _ items: [MenuSlot]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            List(selection: Binding(get: { model.pickedSlot }, set: { model.pickedSlot = $0 })) {
                ForEach(items, id: \.id) { slot in
                    let fixed = DeviceSlots.isFixed(kind, slot.menuItem)
                    Text(DeviceSlots.displayName(slot))
                        .foregroundStyle(fixed ? .tertiary : .primary)
                        .tag(slot.id)
                        .selectionDisabled(fixed || disabled)
                }
            }
            .frame(width: 210, height: 300)
            .disabled(disabled)
        }
    }
}

private struct ColumnTabView: View {
    let settings: DeviceSettings
    let model: DeviceSettingsModel

    /// DEFAULT and ALPHABET are how a list is ordered, not something to show beside a title.
    private var choices: [MenuSlot] { settings.sorts.filter { !DeviceSlots.isFixed(.sort, $0.menuItem) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Default right column").font(.headline)
            Text("Select the item shown next to the track name on CDJ/XDJ.").font(.caption).foregroundStyle(.secondary)
            Picker(
                "Default right column",
                selection: Binding(get: { settings.subColumn }, set: { value in Task { await model.setSubColumn(value) } })
            ) {
                Text("Not Specified").tag(Int64?.none)
                ForEach(choices, id: \.id) { Text(DeviceSlots.displayName($0)).tag(Int64?.some($0.menuItem)) }
            }
            .labelsHidden()
            .frame(width: 260)
            .disabled(!settings.hasLibrarySettings)
        }
    }
}

private struct ColorTabView: View {
    let settings: DeviceSettings
    let model: DeviceSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Customize Color Comments").font(.headline)
            ForEach(settings.colors, id: \.id) { color in
                ColorNameRow(color: color, disabled: !settings.hasLibrarySettings) { name in
                    Task { await model.renameColor(id: color.id, to: name) }
                }
            }
        }
    }
}

private struct ColorNameRow: View {
    let color: ColorName
    let disabled: Bool
    let commit: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: TrackColors.dot(UInt8(clamping: color.id))).accessibilityHidden(true)
            TextField("Color comment \(color.id)", text: $draft)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .disabled(disabled)
                .onSubmit { commit(draft) }
        }
        .onAppear { draft = color.name }
        .onChange(of: color.name) { _, new in draft = new }
    }
}

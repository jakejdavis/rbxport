import Foundation
import Observation

/// The Audio pane's state: which output, the sample rate and the buffer size.
///
/// The rate and buffer are remembered and pushed at launch (the engine keeps them until it
/// opens; nothing here opens the output). A change of any of the three drops a live engine; the
/// player reloads its decks at their positions when the `.reset` arrives. Like the React app,
/// the chosen output is not remembered across launches: the system default is used until one
/// is picked again.
@MainActor @Observable
final class AudioSettingsModel {
    static let sampleRates: [UInt32] = [44_100, 48_000, 88_200, 96_000]
    static let bufferSizes: [UInt32] = [64, 128, 256, 512, 1_024, 2_048]
    static let defaultSampleRate: UInt32 = 48_000
    static let defaultBufferSize: UInt32 = 512
    static let sampleRateKey = "audio.sampleRate"
    static let bufferSizeKey = "audio.bufferSize"

    /// One row of the output picker.
    struct Choice: Equatable, Identifiable, Sendable {
        /// `nil` is the system default.
        var id: String?
        var title: String
    }

    private(set) var devices: AudioDevices?
    private(set) var sampleRate: UInt32
    private(set) var bufferSize: UInt32

    @ObservationIgnored private let playback: any PlaybackEngine
    let prefs: PreferencesStore

    init(playback: any PlaybackEngine, defaults: UserDefaults, prefs: PreferencesStore? = nil) {
        self.playback = playback
        let prefs = prefs ?? PreferencesStore(defaults: defaults)
        self.prefs = prefs
        sampleRate = UInt32(prefs.sampleRate)
        bufferSize = UInt32(prefs.bufferSize)
        // Stored, not applied: nothing is dropped and nothing is opened.
        playback.setAudioConfig(sampleRate: sampleRate, bufferFrames: bufferSize)
        // Reset to defaults in Settings changes the store; follow it.
        prefs.onChange { [weak self] key in
            guard let self else { return }
            if key == PrefKeys.sampleRate { self.setSampleRate(UInt32(prefs.sampleRate)) }
            if key == PrefKeys.bufferSize { self.setBufferSize(UInt32(prefs.bufferSize)) }
        }
    }

    /// `512 samples (10.7 ms)`.
    static func caption(frames: UInt32, sampleRate: UInt32) -> String {
        let ms = sampleRate > 0 ? Double(frames) / Double(sampleRate) * 1000 : 0
        return String(format: "%d samples (%.1f ms)", Int(frames), ms)
    }

    var bufferCaption: String { Self.caption(frames: bufferSize, sampleRate: sampleRate) }

    /// The device picker's rows: "System default — <name>", then each output.
    var choices: [Choice] {
        guard let devices else { return [Choice(id: nil, title: "System default")] }
        let defaultName = devices.devices.first { $0.id == devices.defaultId }?.name
        let first = Choice(id: nil, title: defaultName.map { "System default \u{2014} \($0)" } ?? "System default")
        return [first] + devices.devices.map { Choice(id: $0.id, title: $0.name) }
    }

    /// The picker's selection: the chosen output, or the system default when it has gone.
    var chosen: String? {
        guard let id = devices?.chosenId, devices?.devices.contains(where: { $0.id == id }) == true else { return nil }
        return id
    }

    /// Reads the outputs again, as the pane opens (an interface is plugged in while the app
    /// runs). Enumerating opens nothing.
    func refresh() async {
        let playback = playback
        devices = await Task.detached { playback.audioDevices() }.value
    }

    func choose(device id: String?) {
        playback.setAudioDevice(id)
        if var current = devices {
            current.chosenId = id
            devices = current
        }
    }

    func setSampleRate(_ rate: UInt32) {
        guard Self.sampleRates.contains(rate), rate != sampleRate else { return }
        sampleRate = rate
        prefs.sampleRate = Int(rate)
        playback.setAudioConfig(sampleRate: rate, bufferFrames: bufferSize)
    }

    func setBufferSize(_ frames: UInt32) {
        guard Self.bufferSizes.contains(frames), frames != bufferSize else { return }
        bufferSize = frames
        prefs.bufferSize = Int(frames)
        playback.setAudioConfig(sampleRate: sampleRate, bufferFrames: frames)
    }
}

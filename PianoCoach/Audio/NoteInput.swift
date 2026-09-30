import Foundation
import Observation
import PianoCoachCore

/// How the child's notes reach the app.
enum NoteSource: String, CaseIterable, Codable, Identifiable {
    case microphone
    case midiKeyboard

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .midiKeyboard: return "MIDI keyboard"
        }
    }
}

/// Hears the child's piano: notes from the microphone (through `AnalysisWorker`) or from a MIDI keyboard,
/// passed to the game as they happen.
@MainActor
@Observable
final class NoteInput {
    private(set) var isListening = false
    private(set) var listeningError: String?
    /// 0...1 input level for a meter.
    private(set) var inputLevel: Float = 0
    /// A short message for the parent (e.g. no MIDI keyboard found).
    private(set) var notice: String?

    var noteSource: NoteSource = .microphone {
        didSet { if oldValue != noteSource, isListening { restartListening() } }
    }
    var sensitivity: Float = 0.5 {
        didSet { analysis.setSensitivity(sensitivity) }
    }
    /// Removes the app's own piano from the microphone signal.
    var echoCancellation = false {
        didSet { if oldValue != echoCancellation, isListening, noteSource == .microphone { restartListening() } }
    }

    /// Receives every note or chord heard (microphone or MIDI) with its `MonotonicClock` time.
    @ObservationIgnored var noteObserver: ((NoteOnset, Double) -> Void)?
    /// Receives MIDI keys going down (`true`) and up (`false`), to light the keys on screen.
    @ObservationIgnored var keyObserver: ((Int, Bool) -> Void)?

    private let audio: AudioHub
    private let midi: MIDIInputManager
    private let analysis = AnalysisWorker()
    @ObservationIgnored private var grouper = MIDINoteGrouper()
    @ObservationIgnored private var midiFlushTask: Task<Void, Never>?
    /// Bumped by `stopListening`, so a start still waiting for permission doesn't finish afterwards.
    @ObservationIgnored private var generation = 0

    init(audio: AudioHub, midi: MIDIInputManager) {
        self.audio = audio
        self.midi = midi
        analysis.onResult = { [weak self] onsets, level in
            self?.analysisDidProduce(onsets, levelDB: level)
        }
        let worker = analysis
        audio.onRestart = { _ in worker.reset() }
        audio.onFailure = { [weak self] error in
            Task { @MainActor in self?.audioDidFail(error) }
        }
    }

    func startListening() {
        guard !isListening else { return }
        listeningError = nil
        notice = nil
        let gen = generation
        Task { [weak self] in
            // Stopped before this ran: don't start anything.
            guard let self, gen == self.generation else { return }
            switch self.noteSource {
            case .microphone:
                guard await Permissions.requestMicrophone() else {
                    self.listeningError = AudioHub.HubError.permissionDenied.localizedDescription
                    return
                }
                guard gen == self.generation else { return }
                let worker = self.analysis
                self.audio.setChunkHandler { chunk in worker.process(chunk) }
                do {
                    try self.audio.start(voiceProcessing: self.echoCancellation)
                    self.isListening = true
                } catch {
                    self.listeningError = "Couldn't start the microphone: \(error.localizedDescription)"
                }
            case .midiKeyboard:
                self.midi.onNoteOn = { [weak self] note, velocity, time in
                    Task { @MainActor in self?.midiNoteOn(note: note, velocity: velocity, time: time) }
                }
                self.midi.onNoteOff = { [weak self] note, _ in
                    Task { @MainActor in self?.keyObserver?(note, false) }
                }
                do {
                    try self.midi.start()
                    self.isListening = true
                    if self.midi.sourceNames.isEmpty {
                        self.notice = "No MIDI keyboard found. Connect one with USB or Bluetooth."
                    }
                } catch {
                    self.listeningError = "Couldn't connect to MIDI: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Stops hearing notes. The microphone itself keeps running while voice commands use it; the app stops
    /// it when nothing needs it.
    func stopListening() {
        generation += 1
        audio.setChunkHandler(nil)
        midi.onNoteOn = nil
        midi.onNoteOff = nil
        midi.stop()
        midiFlushTask?.cancel()
        // Drop a half-collected chord, so it isn't reported with the first note of the next session.
        _ = grouper.flushAll()
        isListening = false
        inputLevel = 0
    }

    private func restartListening() {
        stopListening()
        analysis.reset()
        startListening()
    }

    private func audioDidFail(_ error: Error) {
        guard noteSource == .microphone, isListening else { return }
        isListening = false
        inputLevel = 0
        listeningError = "The microphone stopped: \(error.localizedDescription)"
    }

    // MARK: - Notes in

    private func analysisDidProduce(_ onsets: [TimedOnset], levelDB: Float) {
        guard noteSource == .microphone, isListening else { return }
        // Map -60...-10 dBFS to 0...1 for the meter.
        inputLevel = max(0, min(1, (levelDB + 60) / 50))
        for timed in onsets { noteObserver?(timed.onset, timed.clockTime) }
    }

    private func midiNoteOn(note: Int, velocity: Int, time: Double) {
        guard noteSource == .midiKeyboard, isListening else { return }
        inputLevel = Float(velocity) / 127
        keyObserver?(note, true)
        if let finished = grouper.noteOn(midi: note, velocity: velocity, time: time) {
            noteObserver?(finished, finished.time)
        }
        midiFlushTask?.cancel()
        let delay = grouper.window + 0.005
        midiFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if let onset = self.grouper.flushAll() { self.noteObserver?(onset, onset.time) }
        }
    }
}

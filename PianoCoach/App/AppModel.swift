import Foundation
import Observation
import PianoCoachCore
#if os(iOS)
import UIKit
#endif

/// App-wide state: the library of songs, the open song, and the shared audio, video, game and learning
/// objects.
///
/// A song starts as a YouTube link. The app listens to the video once (`SongLearner`) and writes down its
/// notes; from then on the game plays its own rendition of the song with the built-in piano, so it can go
/// as slowly or as quickly as the child needs without losing any sound quality.
@MainActor
@Observable
final class AppModel {
    // MARK: Library

    private(set) var pieces: [Piece] = []
    private(set) var libraryError: String?
    @ObservationIgnored private let store: PieceLibraryStore?

    // MARK: Shared services

    let settings: AppSettings
    let audio: AudioHub
    let midi: MIDIInputManager
    let player: YouTubePlayerController
    let input: NoteInput
    let voice: VoiceCommandListener
    let sound: GameSoundPlayer
    let game: GameController
    let learner: SongLearner

    // MARK: Open piece

    private(set) var openPieceID: UUID?
    /// Shows the "learn this song" screen even though the song already has notes ("Learn it again").
    private(set) var isRelearning = false
    /// Why the open song's notes couldn't be read, if they couldn't.
    private(set) var notesError: String?
    /// Presents the list of voice commands.
    var showVoiceHelp = false
    /// Presents the screen that cuts a video's introduction or ending off the song's notes.
    var showTrimScreen = false
    /// A short confirmation shown after a voice command ("Slower · 60 %").
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Off in the screenshot demo, whose songs have made-up video IDs.
    @ObservationIgnored private var loadsVideos = true

    var openPiece: Piece? {
        guard let id = openPieceID else { return nil }
        return pieces.first { $0.id == id }
    }

    /// Whether the open song needs its notes learned (the learn screen shows instead of the game).
    var needsLearning: Bool { game.fullChart == nil || isRelearning }

    init() {
        settings = AppSettings()
        audio = AudioHub()
        midi = MIDIInputManager()
        player = YouTubePlayerController()
        input = NoteInput(audio: audio, midi: midi)
        voice = VoiceCommandListener(audio: audio)
        sound = GameSoundPlayer(hub: audio)
        game = GameController(input: input, sound: sound)
        learner = SongLearner(player: player, audio: audio)

        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        do {
            store = try PieceLibraryStore(rootDirectory: base.appendingPathComponent("PianoCoach", isDirectory: true))
        } catch {
            store = nil
            libraryError = "Couldn't open the library folder: \(error.localizedDescription)"
        }
        pieces = sortedPieces(store?.loadPieces() ?? [])

        game.onFinished = { [weak self] result in self?.recordGame(result) }
        voice.onCommand = { [weak self] command in self?.handle(command) }
        // While the app listens to a video, the microphone may hear words in it ("stop", "again"…), so
        // plain commands are only trusted when nothing is being learned.
        voice.requireWakeWordWhen = { [weak self] in self?.learner.isListening ?? false }
        learner.onLearned = { [weak self] song, origin, pieceID in
            self?.saveLearnedSong(song, origin: origin, pieceID: pieceID)
        }
        applySettings()
        #if DEBUG
        startScreenshotDemoIfRequested()
        #endif
    }

    private func sortedPieces(_ list: [Piece]) -> [Piece] {
        list.sorted { ($0.lastPracticedAt ?? $0.createdAt) > ($1.lastPracticedAt ?? $1.createdAt) }
    }

    private func persist() {
        do {
            try store?.savePieces(pieces)
        } catch {
            libraryError = "Couldn't save the library: \(error.localizedDescription)"
        }
    }

    /// Pushes the current settings into the note input and the voice listener.
    func applySettings() {
        input.noteSource = settings.noteSource
        input.sensitivity = Float(settings.sensitivity)
        input.echoCancellation = settings.echoCancellation
        voice.requireWakeWord = settings.requireWakeWord
        if openPieceID != nil {
            if settings.voiceCommandsEnabled && !voice.isRunning {
                Task { await voice.start() }
            } else if !settings.voiceCommandsEnabled && voice.isRunning {
                voice.stop()
                stopMicrophoneIfIdle()
            }
        }
    }

    // MARK: - Library editing

    /// Adds a piece from a pasted link. Fetches the video title when none is given.
    @discardableResult
    func addPiece(link: String, title: String) async -> Piece? {
        guard let videoID = YouTubeLink.videoID(from: link) else { return nil }
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = await Self.fetchTitle(videoID: videoID) ?? "New song" }
        let piece = Piece(title: name, videoID: videoID, resumeTime: YouTubeLink.startTime(from: link) ?? 0)
        pieces.insert(piece, at: 0)
        persist()
        return piece
    }

    /// Looks up a video's title with YouTube's public oEmbed endpoint (no API key needed).
    static func fetchTitle(videoID: String) async -> String? {
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: YouTubeLink.watchURL(videoID: videoID).absoluteString),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["title"] as? String
    }

    func update(_ piece: Piece) {
        guard let i = pieces.firstIndex(where: { $0.id == piece.id }) else { return }
        pieces[i] = piece
        persist()
    }

    func delete(_ piece: Piece) {
        if openPieceID == piece.id { closePiece() }
        store?.removeFiles(for: piece)
        pieces.removeAll { $0.id == piece.id }
        persist()
    }

    func rename(_ piece: Piece, to title: String) {
        var p = piece
        p.title = title
        update(p)
    }

    // MARK: - Opening a piece

    func openPiece(_ piece: Piece) {
        if openPieceID == piece.id { return }
        if openPieceID != nil { closePiece() }
        openPieceID = piece.id
        isRelearning = false
        loadNotes(for: piece)
        // The video is only needed to learn the song.
        if game.fullChart == nil && loadsVideos { player.load(videoID: piece.videoID, startTime: 0, muted: false) }
        applySettings()
        if var p = openPiece {            // re-read: loadNotes may have stored the difficulty
            p.lastPracticedAt = Date()
            update(p)
        }
    }

    func closePiece() {
        guard openPieceID != nil else { return }
        game.stop()
        learner.cancel()
        input.stopListening()
        player.pause()
        voice.stop()
        sound.stop()
        audio.stop()
        openPieceID = nil
        isRelearning = false
        notesError = nil
    }

    private func stopMicrophoneIfIdle() {
        if !input.isListening && !voice.isRunning && !learner.isListening { audio.stop() }
    }

    /// Reads the open song's notes and hands them to the game.
    private func loadNotes(for piece: Piece) {
        notesError = nil
        var chart: NoteChart?
        if let sheet = piece.sheet, sheet.kind.hasNotes, let store {
            do {
                let score = try ScoreLoader.loadScore(from: try store.data(for: sheet), kind: sheet.kind)
                chart = NoteChart.from(score: score, title: piece.title)
            } catch {
                notesError = "Couldn't read the notes in “\(sheet.originalName)”."
            }
        } else if piece.hasLearnedTrack, let track = store?.loadTrack(forPiece: piece.id) {
            // Notes an older version of the app worked out through the microphone.
            chart = NoteChart.fromListening(track: track, title: piece.title)
        }
        game.load(chart: chart, progress: piece.game)
        if let chart, var p = pieces.first(where: { $0.id == piece.id }) {
            let level = ChartDifficulty.estimate(chart).level
            if p.difficulty != level {
                p.difficulty = level
                update(p)
            }
        }
    }

    // MARK: - Learning a song

    /// Shows the learn screen for the open song, e.g. to learn it again from the video.
    func showLearnScreen() {
        guard let piece = openPiece else { return }
        game.stop()
        isRelearning = game.fullChart != nil
        if player.videoID != piece.videoID { player.load(videoID: piece.videoID, startTime: 0, muted: false) }
    }

    /// Leaves the learn screen for the game (when the song already has notes).
    func closeLearnScreen() {
        learner.cancel()
        player.pause()
        isRelearning = false
        stopMicrophoneIfIdle()
    }

    /// Listens to the open song's video and writes down its notes.
    func learnFromVideo() {
        guard let piece = openPiece else { return }
        game.stop()
        input.stopListening()
        learner.listenToVideo(title: piece.title, pieceID: piece.id)
    }

    /// Writes down the notes of an audio file of the open song.
    func learnFromAudioFile(_ url: URL) {
        guard let piece = openPiece else { return }
        game.stop()
        input.stopListening()
        // Show the learn screen (and its progress) even when the song already has notes.
        isRelearning = game.fullChart != nil
        learner.learn(fromAudioFile: url, title: piece.title, pieceID: piece.id)
    }

    /// Saves learned notes as the song's MIDI file and opens the game.
    private func saveLearnedSong(_ song: ArrangedSong, origin: NotesOrigin, pieceID: UUID) {
        guard let store, var piece = pieces.first(where: { $0.id == pieceID }) else { return }
        do {
            let data = song.midiFileData
            let attachment = try store.importAttachment(data: data, fileExtension: "mid",
                                                        originalName: "\(piece.title).mid")
            if let old = piece.sheet { store.removeAttachment(old) }
            piece.sheet = attachment
            piece.songInfo = SongInfo(origin: origin, keyName: song.keyName, tempoBPM: song.tempoBPM,
                                      noteCount: song.score.notes.count)
            update(piece)
        } catch {
            libraryError = "Couldn't save the song's notes: \(error.localizedDescription)"
            return
        }
        guard openPieceID == pieceID else { return }
        // The microphone may have listened to the video; leave it on only for what still needs it.
        stopMicrophoneIfIdle()
        player.pause()
        isRelearning = false
        loadNotes(for: piece)
        showToast("Your song is ready!")
    }

    /// Uses a MIDI or MusicXML file as the open song's notes.
    func importNotes(from url: URL) throws {
        guard let store, var piece = openPiece else { return }
        let attachment = try store.importAttachment(from: url)
        let score: Score
        do {
            guard attachment.kind.hasNotes else { throw ImportError.noNotes }
            score = try ScoreLoader.loadScore(from: try store.data(for: attachment), kind: attachment.kind)
        } catch {
            store.removeAttachment(attachment)
            throw error
        }
        if let old = piece.sheet { store.removeAttachment(old) }
        piece.sheet = attachment
        piece.songInfo = SongInfo(origin: .sheetMusic, tempoBPM: score.initialTempoBPM, noteCount: score.notes.count)
        update(piece)
        learner.cancel()
        player.pause()
        isRelearning = false
        loadNotes(for: piece)
    }

    // MARK: - Trimming

    /// The open song's notes as a score (what trimming works on), if they can be read.
    func openScore() -> Score? {
        guard let store, let sheet = openPiece?.sheet, sheet.kind.hasNotes else { return nil }
        return try? ScoreLoader.loadScore(from: try store.data(for: sheet), kind: sheet.kind)
    }

    /// Keeps only the notes between two beats of the open song (as a new MIDI file) — to drop a video's
    /// spoken introduction or the applause at the end — and reloads the game with them.
    func trimSong(fromBeat start: Double, toBeat end: Double) {
        guard let store, var piece = openPiece, let score = openScore(),
              let trimmed = ScoreTrimmer.trim(score, from: start, to: end) else {
            libraryError = "There would be no notes left."
            return
        }
        game.stop()
        do {
            let attachment = try store.importAttachment(data: MIDIFileWriter.data(for: trimmed), fileExtension: "mid",
                                                        originalName: "\(piece.title).mid")
            if let old = piece.sheet { store.removeAttachment(old) }
            piece.sheet = attachment
            var info = piece.songInfo ?? SongInfo(origin: .sheetMusic, tempoBPM: trimmed.initialTempoBPM, noteCount: 0)
            info.noteCount = trimmed.notes.count
            piece.songInfo = info
            update(piece)
        } catch {
            libraryError = "Couldn't save the trimmed notes: \(error.localizedDescription)"
            return
        }
        loadNotes(for: piece)
        showToast("Kept \(trimmed.notes.count) notes")
    }

    enum ImportError: LocalizedError {
        case noNotes

        var errorDescription: String? { "That file has no notes. Choose a MIDI or MusicXML file." }
    }

    /// The open song's notes as a file, for sharing (a MIDI file for learned songs).
    var notesFileURL: URL? {
        guard let store, let sheet = openPiece?.sheet, sheet.kind.hasNotes else { return nil }
        return store.url(for: sheet)
    }

    // MARK: - Game

    /// Saves a finished game into the piece's progress and returns the level change to celebrate.
    private func recordGame(_ result: GameResult) -> LevelChange? {
        guard var piece = openPiece else { return nil }
        var progress = piece.game ?? GameProgress(speed: result.startSpeed)
        let change = progress.record(result)
        piece.game = progress
        update(piece)
        return change
    }

    // MARK: - Voice commands

    func handle(_ command: VoiceCommand) {
        guard openPieceID != nil else { return }
        if case .help = command {
            showVoiceHelp = true
            showToast(command.confirmation)
            return
        }
        guard !needsLearning else {
            // Say why nothing happens rather than ignoring the child.
            showToast("The game starts once the song's notes are ready")
            return
        }
        var confirmation = command.confirmation
        switch command {
        case .play: game.play()
        case .pause: game.hold()
        case .slower:
            game.changeSpeed(by: -0.1)
            confirmation += " · \(Int((game.currentSpeed * 100).rounded())) %"
        case .faster:
            game.changeSpeed(by: 0.1)
            confirmation += " · \(Int((game.currentSpeed * 100).rounded())) %"
        case .normalSpeed: game.setSpeed(1)
        case .setSpeed(let rate): game.setSpeed(rate)
        case .listen:
            if game.phase == .demo { game.resumeDemo() } else { game.playDemo() }
        case .showNotes: game.display = .notes
        case .showKeys: game.display = .keys
        case .hands(let hands):
            if game.phase != .ready && game.phase != .demo { game.stop() }
            game.hands = hands
        case .again: game.startOver()
        case .soundOn: sound.isMuted = false
        case .soundOff: sound.isMuted = true
        case .help: break
        }
        showToast(confirmation)
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    #if DEBUG
    /// Screenshot mode used by CI: `-screenshot-demo keys|notes|start|learn|trim [landscape]` opens a built-in
    /// song (without voice commands, so no permission prompts cover the screen).
    private func startScreenshotDemoIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-screenshot-demo") else { return }
        let scene = arguments.dropFirst(flag + 1).joined(separator: " ")
        settings.voiceCommandsEnabled = false
        loadsVideos = false
        if scene.contains("learn") {
            let piece = Piece(title: "Clair de Lune", videoID: "ClairDeLune")
            pieces.insert(piece, at: 0)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                self?.openPiece(piece)
            }
            return
        }
        let piece: Piece
        if let existing = pieces.first(where: { $0.title == DemoSong.title }) {
            piece = existing
        } else {
            var demo = Piece(title: DemoSong.title, videoID: "Ode2JoyDemo")
            // Saved as a MIDI file, like a song the app learned.
            demo.sheet = try? store?.importAttachment(data: MIDIFileWriter.data(for: DemoSong.score), fileExtension: "mid",
                                                      originalName: "\(DemoSong.title).mid")
            demo.difficulty = ChartDifficulty.estimate(DemoSong.chart).level
            demo.songInfo = SongInfo(origin: .video, keyName: "C major", tempoBPM: 100, noteCount: DemoSong.chart.notes.count)
            // A few games already played, so the library shows a level and stars.
            var progress = GameProgress(speed: 0.7)
            progress.gamesPlayed = 3
            progress.bestStars = 2
            progress.bestAccuracy = 0.86
            progress.bestScore = 2_450
            demo.game = progress
            piece = demo
            pieces.insert(piece, at: 0)
            persist()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            #if os(iOS)
            if scene.contains("landscape"),
               let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
            }
            #endif
            self.openPiece(piece)
            self.game.display = scene.contains("notes") ? .notes : .keys
            if scene.contains("trim") {
                self.showTrimScreen = true
                return
            }
            guard !scene.contains("start") else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.game.listensForNotes = false
            self.game.start()
            self.playScreenshotGame()
        }
    }

    /// Plays the notes a Learn game waits for, a moment after it starts waiting, like a child following along.
    private func playScreenshotGame() {
        Task { @MainActor [weak self] in
            var waitingSince: Double?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let game = self?.game else { return }
                switch game.phase {
                case .ready, .countIn, .paused: continue
                case .playing: break
                default: return
                }
                guard game.isWaiting else {
                    waitingSince = nil
                    continue
                }
                let now = MonotonicClock.now()
                if let since = waitingSince {
                    if now - since > 0.25 {
                        for midi in game.upcomingKeys.sorted() { game.tapKey(midi) }
                        waitingSince = nil
                    }
                } else {
                    waitingSince = now
                }
            }
        }
    }
    #endif
}

import Foundation
import Observation
import PianoCoachCore
#if os(iOS)
import UIKit
#endif

/// Sheet music ready to display for the open piece.
enum SheetContent: Equatable {
    /// MusicXML text rendered with OpenSheetMusicDisplay (with a moving cursor).
    case musicXML(String)
    case pdf(URL)
    case image(URL)
}

/// The two ways to practise a piece.
enum PracticeTab: String, CaseIterable, Identifiable {
    /// The falling-notes game.
    case game
    /// The YouTube video, paced by the coach.
    case video

    var id: String { rawValue }
    var displayName: String { self == .game ? "Game" : "Video" }
}

/// App-wide state: the library of pieces, the open piece, and the shared audio/video/coach objects.
@MainActor
@Observable
final class AppModel {
    // MARK: Library

    private(set) var pieces: [Piece] = []
    private(set) var libraryError: String?
    @ObservationIgnored private let store: PieceLibraryStore?

    // MARK: Shared services

    let settings: AppSettings
    let audio: AudioInputHub
    let midi: MIDIInputManager
    let player: YouTubePlayerController
    let coach: CoachEngine
    let voice: VoiceCommandListener
    let sound: GameSoundPlayer
    let game: GameController

    // MARK: Open piece

    private(set) var openPieceID: UUID?
    private(set) var sheetContent: SheetContent?
    private(set) var sheetError: String?
    /// Whether the sheet-music panel is visible.
    var showSheet = false
    /// Presents the list of voice commands.
    var showVoiceHelp = false
    /// A short confirmation shown after a voice command ("Slower").
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Measures of the open piece's score (for sync setup), if it has notes.
    private(set) var openScore: Score?
    /// Game or video.
    var practiceTab: PracticeTab = .game {
        didSet { if oldValue != practiceTab { practiceTabChanged() } }
    }

    var openPiece: Piece? {
        guard let id = openPieceID else { return nil }
        return pieces.first { $0.id == id }
    }

    init() {
        settings = AppSettings()
        audio = AudioInputHub()
        midi = MIDIInputManager()
        player = YouTubePlayerController()
        coach = CoachEngine(player: player, audio: audio, midi: midi)
        voice = VoiceCommandListener(audio: audio)
        sound = GameSoundPlayer()
        game = GameController(coach: coach, sound: sound)

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

        coach.onTrackLearned = { [weak self] track in self?.saveLearnedTrack(track) }
        game.onFinished = { [weak self] result in self?.recordGame(result) }
        voice.onCommand = { [weak self] command in self?.handle(command) }
        // While the video is audible, the microphone also hears the video (a teacher saying "stop",
        // "again"…), so plain commands are only trusted when the video is quiet.
        voice.requireWakeWordWhen = { [weak self] in
            guard let player = self?.player else { return false }
            return player.isPlaying && !player.isMuted
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

    /// Pushes the current settings into the coach, voice listener and sheet.
    func applySettings() {
        coach.noteSource = settings.noteSource
        coach.sensitivity = Float(settings.sensitivity)
        coach.muteVideoWhileListening = settings.muteVideoWhileListening
        coach.echoCancellation = settings.echoCancellation
        coach.learnLatency = settings.learnLatency
        coach.configure(silenceTimeout: settings.silenceTimeout, pauseLead: settings.maxLead,
                        allowFasterThanNormal: settings.allowFasterThanNormal)
        voice.requireWakeWord = settings.requireWakeWord
        if openPieceID != nil {
            if settings.voiceCommandsEnabled && !voice.isRunning {
                Task { await voice.start() }
            } else if !settings.voiceCommandsEnabled && voice.isRunning {
                voice.stop()
                stopAudioIfIdle()
            }
        }
    }

    // MARK: - Library editing

    /// Adds a piece from a pasted link. Fetches the video title when none is given.
    @discardableResult
    func addPiece(link: String, title: String) async -> Piece? {
        guard let videoID = YouTubeLink.videoID(from: link) else { return nil }
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = await Self.fetchTitle(videoID: videoID) ?? "New piece" }
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
        loadSheetAndScore(for: piece)
        showSheet = sheetContent != nil
        let learned = piece.hasLearnedTrack ? store?.loadTrack(forPiece: piece.id) : nil
        coach.attach(score: openScore, syncMap: piece.syncMap, learned: learned, manualRate: piece.manualRate)
        coach.loop = piece.loop
        player.load(videoID: piece.videoID, startTime: piece.resumeTime, muted: false)
        loadGame(for: piece, learned: learned)
        applySettings()
        if var p = openPiece {            // re-read: loadGame may have stored the difficulty
            p.lastPracticedAt = Date()
            update(p)
        }
        if practiceTab == .video { practiceTabChanged() } else { practiceTab = game.chart == nil ? .video : .game }
    }

    func closePiece() {
        guard var piece = openPiece else { return }
        game.stop()
        coach.cancelLearning()
        coach.setMode(.off)
        coach.stopListening()
        player.pause()
        voice.stop()
        stopAudioIfIdle()
        piece.resumeTime = player.currentTime
        piece.loop = coach.loop
        update(piece)
        openPieceID = nil
        openScore = nil
        sheetContent = nil
        sheetError = nil
    }

    private func stopAudioIfIdle() {
        if !coach.isListening && !voice.isRunning && !coach.isLearning { audio.stop() }
    }

    private func loadSheetAndScore(for piece: Piece) {
        sheetContent = nil
        sheetError = nil
        openScore = nil
        guard let store else { return }
        if let sheet = piece.sheet, sheet.kind.hasNotes {
            do {
                openScore = try ScoreLoader.loadScore(from: try store.data(for: sheet), kind: sheet.kind)
            } catch {
                sheetError = "Couldn't read the notes in “\(sheet.originalName)”."
            }
        }
        if let display = piece.sheetForDisplay {
            switch display.kind {
            case .musicXML, .compressedMusicXML:
                if let data = try? store.data(for: display),
                   let text = try? ScoreLoader.musicXMLText(from: data, kind: display.kind) {
                    sheetContent = .musicXML(text)
                } else {
                    sheetError = "Couldn't open “\(display.originalName)”."
                }
            case .pdf:
                sheetContent = .pdf(store.url(for: display))
            case .image:
                sheetContent = .image(store.url(for: display))
            case .midi:
                break
            }
        }
    }

    // MARK: - Sheet music & sync

    /// Imports a sheet-music file for a piece. MusicXML/MIDI replace the notes; PDFs/images become the
    /// displayed sheet (kept alongside MIDI notes).
    func attachSheet(from url: URL, to piece: Piece) throws {
        guard let store else { return }
        let attachment = try store.importAttachment(from: url)
        var p = piece
        if attachment.kind.hasNotes {
            // Validate before replacing anything.
            let score = try ScoreLoader.loadScore(from: try store.data(for: attachment), kind: attachment.kind)
            if let old = p.sheet { store.removeAttachment(old) }
            p.sheet = attachment
            if attachment.kind != .midi, let old = p.displaySheet {
                store.removeAttachment(old)
                p.displaySheet = nil
            }
            let bpm = p.videoBPM ?? score.initialTempoBPM ?? 90
            if p.videoBPM == nil { p.videoBPM = bpm }
            p.syncMap = SyncMap(bpm: bpm, offset: p.syncMap?.offset ?? 0)
        } else {
            if let old = p.displaySheet { store.removeAttachment(old) }
            if let old = p.sheet, !old.kind.hasNotes { store.removeAttachment(old); p.sheet = nil }
            if p.sheet == nil { p.sheet = attachment } else { p.displaySheet = attachment }
        }
        update(p)
        if openPieceID == p.id { reloadOpenPiece(p) }
    }

    func removeSheets(from piece: Piece) {
        var p = piece
        if let s = p.sheet { store?.removeAttachment(s) }
        if let s = p.displaySheet { store?.removeAttachment(s) }
        p.sheet = nil
        p.displaySheet = nil
        p.syncMap = nil
        update(p)
        if openPieceID == p.id { reloadOpenPiece(p) }
    }

    private func reloadOpenPiece(_ piece: Piece) {
        loadSheetAndScore(for: piece)
        let learned = piece.hasLearnedTrack ? store?.loadTrack(forPiece: piece.id) : nil
        coach.attach(score: openScore, syncMap: piece.syncMap, learned: learned, manualRate: piece.manualRate)
        loadGame(for: piece, learned: learned)
    }

    // MARK: - Game

    /// Builds the game's notes: exact from sheet music when there is some, otherwise worked out from
    /// what the coach heard while listening to the video.
    private func loadGame(for piece: Piece, learned: FollowTrack?) {
        var chart: NoteChart?
        if let score = openScore {
            chart = NoteChart.from(score: score, title: piece.title)
        } else if let learned {
            chart = NoteChart.fromListening(track: learned, title: piece.title)
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

    /// Saves a finished game into the piece's progress and returns the level change to celebrate.
    private func recordGame(_ result: GameResult) -> LevelChange? {
        guard var piece = openPiece else { return nil }
        var progress = piece.game ?? GameProgress(speed: result.startSpeed)
        let change = progress.record(result)
        piece.game = progress
        update(piece)
        return change
    }

    /// Makes the game build its notes by listening to the video (the coach's learning pass).
    func buildGameByListening() {
        practiceTab = .video
        coach.startLearning()
    }

    private func practiceTabChanged() {
        switch practiceTab {
        case .game:
            coach.cancelLearning()
            coach.setMode(.off)
            player.pause()
        case .video:
            game.stop()
        }
    }

    /// Sets the video's tempo (quarter notes per minute) and keeps the sync's start point.
    func setTempo(_ bpm: Double, for piece: Piece) {
        guard bpm > 10, bpm < 400 else { return }
        var p = piece
        p.videoBPM = bpm
        if var sync = p.syncMap {
            sync.bpm = bpm
            p.syncMap = sync
        } else if openScore != nil || p.sheet?.kind.hasNotes == true {
            p.syncMap = SyncMap(bpm: bpm, offset: 0)
        }
        update(p)
        if openPieceID == p.id { coach.updateSync(p.syncMap) }
    }

    /// "The first note of the music is here": aligns the score's first note with `videoTime`.
    func setSyncStart(videoTime: Double, for piece: Piece) {
        guard let score = openScore, let first = score.events.first else { return }
        var p = piece
        let bpm = p.syncMap?.bpm ?? p.videoBPM ?? score.initialTempoBPM ?? 90
        p.syncMap = SyncMap(bpm: bpm, offset: videoTime - first.beat * 60 / bpm)
        update(p)
        if openPieceID == p.id { coach.updateSync(p.syncMap) }
    }

    /// Nudges the whole sync earlier/later by `seconds`.
    func nudgeSync(by seconds: Double, for piece: Piece) {
        guard var sync = piece.syncMap else { return }
        var p = piece
        if sync.anchors.isEmpty {
            sync.offset += seconds
        } else {
            let shifted = sync.anchors.map { SyncAnchor(videoTime: $0.videoTime + seconds, beat: $0.beat) }
            sync = SyncMap(bpm: sync.bpm, offset: sync.offset + seconds, anchors: shifted)
        }
        p.syncMap = sync
        update(p)
        if openPieceID == p.id { coach.updateSync(p.syncMap) }
    }

    /// Replaces the sync with anchors tapped along with the video (one tap per measure, starting at measure 1).
    func applyTappedSync(measureTapTimes: [Double], for piece: Piece) {
        guard let score = openScore, measureTapTimes.count >= 2 else { return }
        let fullMeasures = score.measures.filter { $0.lengthBeats + 1e-6 >= $0.timeSignature.quarterBeatsPerMeasure }
        let anchors = zip(measureTapTimes, fullMeasures).map { SyncAnchor(videoTime: $0.0, beat: $0.1.startBeat) }
        guard let first = anchors.first, let last = anchors.last, last.videoTime > first.videoTime else { return }
        let bpm = (last.beat - first.beat) / (last.videoTime - first.videoTime) * 60
        var p = piece
        p.videoBPM = bpm
        p.syncMap = SyncMap(bpm: bpm, offset: first.videoTime - first.beat * 60 / bpm, anchors: anchors)
        update(p)
        if openPieceID == p.id { coach.updateSync(p.syncMap) }
    }

    // MARK: - Learned tracks

    private func saveLearnedTrack(_ track: FollowTrack) {
        guard var piece = openPiece else { return }
        do {
            try store?.saveTrack(track, forPiece: piece.id)
            piece.hasLearnedTrack = true
            update(piece)
            if openScore == nil { loadGame(for: piece, learned: track) }
        } catch {
            libraryError = "Couldn't save what the coach learned: \(error.localizedDescription)"
        }
    }

    func forgetLearnedTrack(for piece: Piece) {
        store?.removeTrack(forPiece: piece.id)
        var p = piece
        p.hasLearnedTrack = false
        update(p)
        if openPieceID == p.id {
            coach.forgetLearnedTrack()
            if openScore == nil { game.load(chart: nil, progress: p.game) }
        }
    }

    // MARK: - Practice preferences

    func setPreferredMode(_ mode: CoachMode) {
        coach.setMode(mode)
        if var p = openPiece {
            p.preferredMode = coach.mode
            update(p)
        }
    }

    func setSpeed(_ rate: Double) {
        coach.setSpeed(rate)
        if var p = openPiece, coach.mode != .followMe {
            p.manualRate = coach.speedSetting
            update(p)
        }
    }

    func stepSpeed(by steps: Int) {
        coach.stepSpeed(by: steps)
        if var p = openPiece, coach.mode != .followMe {
            p.manualRate = coach.speedSetting
            update(p)
        }
    }

    // MARK: - Voice commands

    func handle(_ command: VoiceCommand) {
        guard openPieceID != nil else { return }
        switch command {
        case .play: coach.userPlay()
        case .pause: coach.userPause()
        case .slower: stepSpeed(by: -1)
        case .faster: stepSpeed(by: 1)
        case .normalSpeed: setSpeed(1)
        case .setSpeed(let r): setSpeed(r)
        case .showMusic: showSheet = true
        case .hideMusic: showSheet = false
        case .followMe: setPreferredMode(.followMe)
        case .waitForMe: setPreferredMode(.waitForMe)
        case .coachOff: setPreferredMode(.off)
        case .goBack: coach.goBack()
        case .goForward: coach.skip(by: 5)
        case .again: coach.again()
        case .restart: coach.restartPiece()
        case .goToMeasure(let n):
            if !coach.goToMeasure(n) {
                showToast("I need sheet music with notes to find measure \(n)")
                return
            }
        case .loopThis: coach.loopHere()
        case .stopLoop: coach.loop = nil
        case .soundOn: coach.setSound(on: true)
        case .soundOff: coach.setSound(on: false)
        case .help: showVoiceHelp = true
        }
        showToast(command.confirmation)
    }

    #if DEBUG
    /// Screenshot mode used by CI: `-screenshot-demo keys|notes|start [landscape]` opens the built-in demo
    /// song in the game (without voice commands, so no permission prompts cover the screen).
    private func startScreenshotDemoIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-screenshot-demo") else { return }
        let scene = arguments.dropFirst(flag + 1).joined(separator: " ")
        settings.voiceCommandsEnabled = false
        let piece: Piece
        if let existing = pieces.first(where: { $0.title == DemoSong.title }) {
            piece = existing
        } else {
            piece = Piece(title: DemoSong.title, videoID: "Ode2JoyDemo")
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
            self.game.load(chart: DemoSong.chart, progress: GameProgress(speed: 0.7))
            self.practiceTab = .game
            self.game.display = scene.contains("notes") ? .notes : .keys
            guard !scene.contains("start") else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.game.playDemo()
        }
    }
    #endif

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

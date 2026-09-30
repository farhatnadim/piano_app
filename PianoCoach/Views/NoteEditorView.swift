import PianoCoachCore
import SwiftUI

/// Fixes a learned song's notes on its sheet music, with the video as the reference: the video plays on
/// top, the music scrolls underneath in time with it, and the built-in piano can play the notes along with
/// the video so wrong notes are heard as well as seen.
///
/// Tap a note (anywhere near its head) to select it, then move it up or down (a semitone or an octave),
/// set its length with the note-value buttons (whole to sixteenth, dotted or not), give it to the other
/// hand, or delete it. "Add" mode puts a new note where the staff is tapped. Dragging the music sideways
/// scrubs the video. If the notes run early or late against the video, the "Align" buttons shift them.
struct NoteEditorView: View {
    @Environment(AppModel.self) private var model

    struct EditableNote: Identifiable, Equatable {
        let id: UUID
        var note: ScoreNote
    }

    private let score: Score
    private let tempoBPM: Double
    @State private var notes: [EditableNote]
    @State private var selection: UUID?
    /// Seconds into the video where beat 0 falls.
    @State private var offset: Double
    @State private var hearNotes = true
    @State private var addMode = false
    /// The length new notes get (the last one chosen).
    @State private var newNoteValue = NoteValue.quarter
    /// When `player.currentTime` last changed, to run the playhead smoothly between its 100 ms updates.
    @State private var timeUpdatedAt = MonotonicClock.now()
    @State private var lastHeardTime: Double?
    @State private var sounding: Set<Int> = []
    @State private var dragStart: Double?
    @State private var edited = false

    init(score: Score, chart: NoteChart) {
        self.score = score
        tempoBPM = score.initialTempoBPM ?? chart.beatsPerMinute
        _notes = State(initialValue: score.notes.map { EditableNote(id: UUID(), note: $0) })
        _offset = State(initialValue: chart.videoTimeOfBeatZero ?? 0)
    }

    private var secondsPerBeat: Double { 60 / max(1, tempoBPM) }
    private func beat(atVideoTime t: Double) -> Double { (t - offset) / secondsPerBeat }

    /// The notes as a chart and as sheet music, and which note each chart note is.
    struct Written {
        let chart: NoteChart
        let order: [UUID]
        let sheet: SheetMusic
    }

    /// Worked out again only when the notes change (the view itself redraws with every video tick).
    @State private var writtenCache: Written?

    private func write() -> Written {
        let sorted = notes.sorted { ($0.note.beat, $0.note.midi) < ($1.note.beat, $1.note.midi) }
        let chart = NoteChart(title: score.title ?? "", notes: sorted.map {
            ChartNote(id: 0, midi: $0.note.midi, time: $0.note.beat, duration: $0.note.durationBeats, hand: $0.note.hand,
                      velocity: $0.note.velocity)
        }, beatsPerMinute: tempoBPM, barLines: score.measures.map(\.startBeat), source: .score,
                              keyFifths: score.keyFifths, timeSignatures: score.measures.map(\.timeSignature))
        return Written(chart: chart, order: sorted.map(\.id), sheet: SheetMusic(chart: chart))
    }

    var body: some View {
        let player = model.player
        let written = writtenCache ?? write()
        let sheet = written.sheet
        let selectedChartIDs = Set(written.order.enumerated().filter { $0.element == selection }.map(\.offset))
        VStack(spacing: 12) {
            WebViewContainer(webView: player.webView)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxHeight: 240)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            controls
            SheetEditorCanvas(sheet: sheet, chart: written.chart, selected: selectedChartIDs, secondsPerBeat: secondsPerBeat,
                              offset: offset, playerTime: player.currentTime, playerRate: player.rate,
                              isPlaying: player.state == .playing, timeUpdatedAt: timeUpdatedAt,
                              onTap: { tapped($0, order: written.order) },
                              onDrag: { drag($0) })
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let selected = notes.first(where: { $0.id == selection }) {
                selectionBar(selected)
            } else {
                Text(addMode ? "Tap the staff where a note is missing." : "Tap a note to change its pitch or length, or remove it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 104)
            }
        }
        .padding(16)
        .navigationTitle("Fix the notes")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.closeNoteEditor() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    model.saveEditedNotes(notes.map(\.note), videoTimeOfBeatZero: offset)
                    model.closeNoteEditor()
                }
                .disabled(!edited || notes.isEmpty)
            }
        }
        .onChange(of: notes, initial: true) { writtenCache = write() }
        .onChange(of: player.currentTime) { _, _ in timeUpdatedAt = MonotonicClock.now() }
        .onChange(of: player.state) { _, state in if state != .playing { silence() } }
        .onReceive(Timer.publish(every: 1 / 30, on: .main, in: .common).autoconnect()) { _ in heartbeat() }
        .onDisappear { silence() }
        #if DEBUG
        .onAppear {
            // Screenshots: `-screenshot-demo edit select` opens with the first note selected.
            if ProcessInfo.processInfo.arguments.contains("select"), selection == nil {
                selection = notes.min { ($0.note.beat, $0.note.midi) < ($1.note.beat, $1.note.midi) }?.id
            }
        }
        #endif
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                model.player.state == .playing ? model.player.pause() : model.player.play()
            } label: {
                Image(systemName: model.player.state == .playing ? "pause.fill" : "play.fill")
                    .frame(width: 24)
            }
            .buttonStyle(.borderedProminent)
            .help("Play or pause the video")
            Toggle(isOn: $hearNotes) { Label("Hear my notes", systemImage: "pianokeys") }
                .toggleStyle(.button)
                .help("Play the app's notes on the piano along with the video")
            Toggle(isOn: $addMode) { Label("Add", systemImage: "plus") }
                .toggleStyle(.button)
                .help("Tap the staff to add a note")
            Spacer()
            HStack(spacing: 6) {
                Text("Align")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button { nudge(-0.1) } label: { Image(systemName: "arrow.left") }
                    .help("Move the notes 0.1 s earlier")
                Text(String(format: "%+.1f s", offset))
                    .font(.callout.monospacedDigit())
                    .frame(width: 60)
                Button { nudge(0.1) } label: { Image(systemName: "arrow.right") }
                    .help("Move the notes 0.1 s later")
            }
            .buttonStyle(.bordered)
        }
        .font(.callout)
    }

    private func selectionBar(_ selected: EditableNote) -> some View {
        let name = NoteSpelling.spell(selected.note.midi, keyFifths: score.keyFifths).nameWithOctave
        let current = NoteValue.nearest(toBeats: selected.note.durationBeats)
        let room = roomAfter(selected)
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(name)
                    .font(.title3.weight(.bold).monospacedDigit())
                    .frame(width: 60)
                Button { move(selected.id, by: -1) } label: { Image(systemName: "arrow.down") }
                    .help("A semitone lower")
                Button { move(selected.id, by: 1) } label: { Image(systemName: "arrow.up") }
                    .help("A semitone higher")
                Button { move(selected.id, by: -12) } label: { Text("−8va") }
                    .help("An octave lower")
                Button { move(selected.id, by: 12) } label: { Text("+8va") }
                    .help("An octave higher")
                Button {
                    update(selected.id) { $0.hand = $0.hand == .left ? .right : .left }
                } label: {
                    Label(selected.note.hand == .left ? "Left hand" : "Right hand",
                          systemImage: selected.note.hand == .left ? "hand.point.left" : "hand.point.right")
                }
                .help("Give the note to the other hand")
                Spacer()
                Button(role: .destructive) { remove(selected.id) } label: { Label("Delete", systemImage: "trash") }
            }
            HStack(spacing: 8) {
                Text("Length")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                ForEach([NoteValue.whole, .half, .quarter, .eighth, .sixteenth], id: \.base) { base in
                    let value = NoteValue(base: base.base, dotted: current.dotted && base.base > 1)
                    let isCurrent = current.base == base.base
                    Button { setValue(value, of: selected.id) } label: {
                        NoteValueIcon(value: NoteValue(base: base.base)).frame(width: 30, height: 34)
                    }
                    .tint(isCurrent ? .accentColor : .gray)
                    .disabled(value.beats > room + 1e-6)
                    .help(Self.valueName(base))
                }
                Button {
                    setValue(NoteValue(base: current.base, dotted: !current.dotted), of: selected.id)
                } label: {
                    Text("Dot").frame(height: 34)
                }
                .tint(current.dotted ? .accentColor : .gray)
                .disabled(current.base == 1 || (!current.dotted && NoteValue(base: current.base, dotted: true).beats > room + 1e-6))
                .help("A dotted note lasts half as long again")
                Spacer()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .font(.callout)
        .frame(height: 104)
    }

    static func valueName(_ value: NoteValue) -> String {
        switch value.base {
        case 1: return "Whole note"
        case 2: return "Half note"
        case 4: return "Quarter note"
        case 8: return "Eighth note"
        default: return "Sixteenth note"
        }
    }

    // MARK: - Editing

    private func tapped(_ target: SheetEditorCanvas.TapTarget, order: [UUID]) {
        switch target {
        case .note(let chartID):
            guard chartID < order.count else { return }
            selection = order[chartID]
            addMode = false
            if let hit = notes.first(where: { $0.id == selection }) { play(midi: hit.note.midi) }
        case .staff(let beat, let midi, let hand):
            if addMode {
                let note = ScoreNote(midi: midi, beat: max(0, beat), durationBeats: newNoteValue.beats, hand: hand,
                                     measureIndex: 0, velocity: 0.7)
                let added = EditableNote(id: UUID(), note: note)
                notes.append(added)
                selection = added.id
                edited = true
                play(midi: midi)
            } else {
                selection = nil
            }
        }
    }

    /// Beats from the note to the next note of the same hand (the longest it can be written as one voice).
    private func roomAfter(_ selected: EditableNote) -> Double {
        let start = SheetMusic.snap(selected.note.beat)
        let next = notes.filter { $0.id != selected.id && $0.note.hand == selected.note.hand }
            .map { SheetMusic.snap($0.note.beat) }
            .filter { $0 > start + 1e-6 }
            .min()
        return next.map { $0 - start } ?? .infinity
    }

    /// Gives the note a written length, and puts it on the beat grid so it is written exactly so.
    private func setValue(_ value: NoteValue, of id: UUID) {
        update(id) {
            $0.beat = max(0, SheetMusic.snap($0.beat))
            $0.durationBeats = value.beats
        }
        newNoteValue = value
    }

    private func move(_ id: UUID, by semitones: Int) {
        update(id) { $0.midi = max(KeyboardLayout.lowestKey, min(KeyboardLayout.highestKey, $0.midi + semitones)) }
        if let note = notes.first(where: { $0.id == id }) { play(midi: note.note.midi) }
    }

    private func update(_ id: UUID, _ change: (inout ScoreNote) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[index].note)
        edited = true
    }

    private func remove(_ id: UUID) {
        notes.removeAll { $0.id == id }
        selection = nil
        edited = true
    }

    private func nudge(_ seconds: Double) {
        offset = ((offset + seconds) * 10).rounded() / 10
        edited = true
    }

    /// Scrubs the video: `delta` seconds from where the drag began (nil when it ends).
    private func drag(_ delta: Double?) {
        guard let delta else {
            dragStart = nil
            return
        }
        if dragStart == nil {
            dragStart = model.player.currentTime
            model.player.pause()
        }
        if let start = dragStart {
            model.player.seek(to: max(0, start + delta))
        }
    }

    // MARK: - Hearing the notes

    private func play(midi: Int) {
        let sound = model.sound
        guard (try? sound.start()) != nil else { return }
        sound.noteOn(midi, velocity: 0.7)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            sound.noteOff(midi)
        }
    }

    /// Plays the notes the video has just reached on the built-in piano.
    private func heartbeat() {
        let player = model.player
        guard hearNotes, player.state == .playing else {
            lastHeardTime = nil
            return
        }
        let now = player.currentTime + (MonotonicClock.now() - timeUpdatedAt) * player.rate
        defer { lastHeardTime = now }
        guard let last = lastHeardTime, now > last, now - last < 1 else { return }
        let sound = model.sound
        guard (try? sound.start()) != nil else { return }
        let from = beat(atVideoTime: last), to = beat(atVideoTime: now)
        for item in notes {
            let n = item.note
            if n.beat > from && n.beat <= to {
                sound.noteOn(n.midi, velocity: Float(n.velocity ?? 0.7))
                sounding.insert(n.midi)
            }
            let end = n.beat + n.durationBeats
            if end > from && end <= to && sounding.contains(n.midi) {
                sound.noteOff(n.midi)
                sounding.remove(n.midi)
            }
        }
    }

    private func silence() {
        lastHeardTime = nil
        sounding = []
        model.sound.allNotesOff()
    }
}

/// A note value drawn as a note (for the length buttons).
struct NoteValueIcon: View {
    let value: NoteValue

    var body: some View {
        Canvas { context, size in
            let glyph: MusicFont.Glyph
            switch value.base {
            case 1: glyph = .metNoteWhole
            case 2: glyph = .metNoteHalfUp
            case 4: glyph = .metNoteQuarterUp
            case 8: glyph = .metNote8thUp
            default: glyph = .metNote16thUp
            }
            guard let shape = MusicFont.shared.shape(glyph), shape.bounds.height > 0 else { return }
            let space = min(size.height / shape.bounds.height, size.width / max(shape.bounds.width, 1))
            let origin = CGPoint(x: size.width / 2 - shape.bounds.midX * space, y: size.height / 2 + shape.bounds.midY * space)
            context.fill(MusicFont.path(shape, origin: origin, space: space), with: .foreground)
        }
        .accessibilityHidden(true)
    }
}

/// The song's sheet music scrolling with the video, the playhead a third of the way in. A tap picks the
/// note whose head is nearest (within a fingertip), or a place on the staff (to add a note there).
struct SheetEditorCanvas: View {
    let sheet: SheetMusic
    let chart: NoteChart
    let selected: Set<Int>
    let secondsPerBeat: Double
    let offset: Double
    let playerTime: Double
    let playerRate: Double
    let isPlaying: Bool
    let timeUpdatedAt: Double
    let onTap: (TapTarget) -> Void
    /// Drag by seconds (nil when the drag ends).
    let onDrag: (Double?) -> Void

    enum TapTarget {
        case note(chartID: Int)
        /// A place on the staff: the beat (on the sixteenth-note grid), the key and the hand.
        case staff(beat: Double, midi: Int, hand: Hand)
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragging = false

    /// A tap this close to a notehead (in points) picks it: about a fingertip.
    static let touchSlop: CGFloat = 30

    private var paper: Color { Color(white: colorScheme == .dark ? 0.12 : 0.97) }

    /// The video time now, running on smoothly between the player's time updates.
    private var currentTime: Double {
        isPlaying ? playerTime + (MonotonicClock.now() - timeUpdatedAt) * playerRate : playerTime
    }

    private struct Frame {
        let staff: StaffGeometry
        let playheadX: CGFloat
        let pixelsPerBeat: CGFloat
        let playheadBeat: Double
        let visible: ClosedRange<Double>
        func x(_ beat: Double) -> CGFloat { playheadX + CGFloat(beat - playheadBeat) * pixelsPerBeat }
    }

    private func frame(size: CGSize, now: Double) -> Frame {
        let staff = StaffGeometry(size: size, maxSpacing: 20)
        let s = staff.spacing
        let leftEdge = staff.left + SheetMusicRenderer.startWidth(for: sheet, space: s)
        let playheadX = leftEdge + (size.width - leftEdge) * 0.3
        let pixelsPerBeat = max(6 * s, SheetMusicRenderer.minimumPixelsPerBeat(for: sheet, space: s))
        let beat = (now - offset) / secondsPerBeat
        let visible = (beat - Double((playheadX - leftEdge) / pixelsPerBeat))...(beat + Double((size.width - playheadX) / pixelsPerBeat))
        return Frame(staff: staff, playheadX: playheadX, pixelsPerBeat: pixelsPerBeat, playheadBeat: beat, visible: visible)
    }

    private func renderer(_ f: Frame) -> SheetMusicRenderer {
        let playing = f.playheadBeat
        let notes = chart.notes
        return SheetMusicRenderer(sheet: sheet, staff: f.staff, x: f.x, visibleBeats: f.visible, position: playing,
                                  showLetters: true, isDark: colorScheme == .dark, paper: paper,
                                  noteColor: { id in
                                      guard id < notes.count else { return nil }
                                      // The notes sounding at the playhead, in the accent colour.
                                      return notes[id].time <= playing && notes[id].end > playing ? Color.accentColor : nil
                                  },
                                  selected: selected)
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { _ in
                let now = currentTime
                Canvas { context, size in
                    let f = frame(size: size, now: now)
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(paper))
                    renderer(f).draw(in: &context, size: size)
                    let s = f.staff.spacing
                    context.fill(Path(CGRect(x: f.playheadX - 1, y: f.staff.trebleTop - 2 * s, width: 2,
                                             height: f.staff.bassBottom - f.staff.trebleTop + 4 * s)),
                                 with: .color(Color.accentColor.opacity(0.8)))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if abs(value.translation.width) > 12 || dragging {
                            dragging = true
                            let f = frame(size: geo.size, now: currentTime)
                            onDrag(-Double(value.translation.width / f.pixelsPerBeat) * secondsPerBeat)
                        }
                    }
                    .onEnded { value in
                        if dragging {
                            dragging = false
                            onDrag(nil)
                        } else if let target = target(at: value.location, size: geo.size) {
                            onTap(target)
                        }
                    }
            )
        }
        .accessibilityLabel("The song's sheet music in time with the video")
    }

    private func target(at point: CGPoint, size: CGSize) -> TapTarget? {
        let f = frame(size: size, now: currentTime)
        let s = f.staff.spacing
        guard point.x > f.staff.left + SheetMusicRenderer.startWidth(for: sheet, space: s) else { return nil }
        var best: (id: Int, distance: CGFloat)?
        for head in renderer(f).headCenters() {
            let distance = hypot(head.center.x - point.x, head.center.y - point.y)
            if distance <= Self.touchSlop, distance < (best?.distance ?? .infinity) { best = (head.id, distance) }
        }
        if let best { return .note(chartID: best.id) }
        // An empty place: the staff, line or space, and beat under the finger.
        let treble = point.y < (f.staff.trebleBottom + f.staff.bassTop) / 2
        let step: Int
        if treble {
            step = NoteSpelling.trebleBottomLine + Int(((f.staff.trebleBottom - point.y) / (s / 2)).rounded())
        } else {
            step = NoteSpelling.bassTopLine + Int(((f.staff.bassTop - point.y) / (s / 2)).rounded())
        }
        let letters = ["C", "D", "E", "F", "G", "A", "B"]
        let semitones = [0, 2, 4, 5, 7, 9, 11]
        let index = ((step % 7) + 7) % 7
        let octave = Int((Double(step) / 7).rounded(.down))
        let alteration = SheetMusic.keyAlterations(keyFifths: sheet.keyFifths)[letters[index]] ?? 0
        let midi = (octave + 1) * 12 + semitones[index] + alteration
        guard (KeyboardLayout.lowestKey...KeyboardLayout.highestKey).contains(midi) else { return nil }
        let beat = SheetMusic.snap(f.playheadBeat + Double((point.x - f.playheadX) / f.pixelsPerBeat))
        return .staff(beat: beat, midi: midi, hand: treble ? .right : .left)
    }
}

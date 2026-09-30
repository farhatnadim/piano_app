import PianoCoachCore
import SwiftUI

/// Fixes a learned song's notes by hand, with the video as the reference: the video plays on top, the
/// notes scroll underneath in time with it, and the built-in piano can play them along with the video so
/// wrong notes are heard as well as seen.
///
/// Tap a note to select it, then move it up or down (a semitone or an octave), give it to the other hand,
/// or delete it. "Add" mode puts a new note where the roll is tapped. Dragging the roll sideways scrubs the
/// video. If the notes run early or late against the video, the "Align" buttons shift them.
struct NoteEditorView: View {
    @Environment(AppModel.self) private var model

    struct EditableNote: Identifiable, Equatable {
        let id: UUID
        var note: ScoreNote
    }

    private let tempoBPM: Double
    private let barLength: Double
    @State private var notes: [EditableNote]
    @State private var selection: UUID?
    /// Seconds into the video where beat 0 falls.
    @State private var offset: Double
    @State private var hearNotes = true
    @State private var addMode = false
    /// When `player.currentTime` last changed, to run the playhead smoothly between its 100 ms updates.
    @State private var timeUpdatedAt = MonotonicClock.now()
    @State private var lastHeardTime: Double?
    @State private var sounding: Set<Int> = []
    @State private var dragStart: (time: Double, x: CGFloat)?
    @State private var edited = false

    init(score: Score, chart: NoteChart) {
        tempoBPM = score.initialTempoBPM ?? chart.beatsPerMinute
        barLength = score.measures.first?.timeSignature.quarterBeatsPerMeasure ?? 4
        _notes = State(initialValue: score.notes.map { EditableNote(id: UUID(), note: $0) })
        _offset = State(initialValue: chart.videoTimeOfBeatZero ?? 0)
    }

    private var secondsPerBeat: Double { 60 / max(1, tempoBPM) }
    private func videoTime(atBeat beat: Double) -> Double { offset + beat * secondsPerBeat }
    private func beat(atVideoTime t: Double) -> Double { (t - offset) / secondsPerBeat }

    var body: some View {
        let player = model.player
        VStack(spacing: 12) {
            WebViewContainer(webView: player.webView)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxHeight: 260)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            controls
            PianoRollEditor(notes: notes, selection: selection, tempoBPM: tempoBPM, barLength: barLength,
                            offset: offset, playerTime: player.currentTime, playerRate: player.rate,
                            isPlaying: player.state == .playing, timeUpdatedAt: timeUpdatedAt,
                            onTap: { tapped($0) },
                            onDrag: { drag($0) })
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let selected = notes.first(where: { $0.id == selection }) {
                selectionBar(selected)
            } else {
                Text(addMode ? "Tap the roll where a note is missing." : "Tap a note to change or remove it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 52)
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
        .onChange(of: player.currentTime) { _, _ in timeUpdatedAt = MonotonicClock.now() }
        .onChange(of: player.state) { _, state in if state != .playing { silence() } }
        .onReceive(Timer.publish(every: 1 / 30, on: .main, in: .common).autoconnect()) { _ in heartbeat() }
        .onDisappear { silence() }
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
                .help("Tap the roll to add a note")
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
        let name = NoteSpelling.spell(selected.note.midi).nameWithOctave
        return HStack(spacing: 10) {
            Text(name)
                .font(.title3.weight(.bold).monospacedDigit())
                .frame(width: 56)
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
        .buttonStyle(.bordered)
        .controlSize(.large)
        .font(.callout)
        .frame(height: 52)
    }

    // MARK: - Editing

    private func tapped(_ target: PianoRollEditor.TapTarget) {
        switch target {
        case .note(let id):
            selection = id
            addMode = false
            if let hit = notes.first(where: { $0.id == id }) { play(midi: hit.note.midi) }
        case .empty(let time, let midi):
            addOrDeselect(time: time, midi: midi)
        }
    }

    private func addOrDeselect(time: Double, midi: Int) {
        let b = beat(atVideoTime: time)
        if addMode {
            let note = ScoreNote(midi: midi, beat: max(0, b), durationBeats: 1, hand: midi >= 60 ? .right : .left,
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

    /// Scrubs the video: `delta` seconds from where the drag began.
    private func drag(_ delta: Double?) {
        guard let delta else {
            dragStart = nil
            return
        }
        if dragStart == nil {
            dragStart = (model.player.currentTime, 0)
            model.player.pause()
        }
        if let start = dragStart {
            model.player.seek(to: max(0, start.time + delta))
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

/// The song's notes on a time × pitch grid that scrolls with the video, the playhead a third of the way in.
private struct PianoRollEditor: View {
    let notes: [NoteEditorView.EditableNote]
    let selection: UUID?
    let tempoBPM: Double
    let barLength: Double
    let offset: Double
    let playerTime: Double
    let playerRate: Double
    let isPlaying: Bool
    let timeUpdatedAt: Double
    /// What a tap landed on: a note (the nearest one within a finger's reach), or an empty spot.
    enum TapTarget {
        case note(UUID)
        case empty(time: Double, midi: Int)
    }

    let onTap: (TapTarget) -> Void
    /// Drag by seconds (nil when the drag ends).
    let onDrag: (Double?) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragging = false

    static let pixelsPerSecond: CGFloat = 200
    static let gutter: CGFloat = 40
    static let playheadFraction: CGFloat = 0.3
    /// A tap this close to a note (in points) picks it: about a fingertip.
    static let touchSlop: CGFloat = 28

    private var rows: ClosedRange<Int> {
        let pitches = notes.map(\.note.midi)
        let low = max(KeyboardLayout.lowestKey, (pitches.min() ?? 55) - 3)
        let high = min(KeyboardLayout.highestKey, (pitches.max() ?? 79) + 3)
        return low...max(low + 12, high)
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { _ in
                let now = currentTime
                Canvas { ctx, size in draw(in: &ctx, size: size, now: now) }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if abs(value.translation.width) > 12 || dragging {
                            dragging = true
                            onDrag(-Double(value.translation.width / Self.pixelsPerSecond))
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
        .background(Color(white: colorScheme == .dark ? 0.12 : 0.96))
        .accessibilityLabel("The song's notes in time with the video")
    }

    private func rowHeight(_ size: CGSize) -> CGFloat { size.height / CGFloat(rows.count) }

    private func y(_ midi: Int, size: CGSize) -> CGFloat {
        CGFloat(rows.upperBound - midi) * rowHeight(size)
    }

    private func x(videoTime t: Double, now: Double, size: CGSize) -> CGFloat {
        Self.gutter + (size.width - Self.gutter) * Self.playheadFraction + CGFloat(t - now) * Self.pixelsPerSecond
    }

    /// The video time now, running on smoothly between the player's time updates.
    private var currentTime: Double {
        isPlaying ? playerTime + (MonotonicClock.now() - timeUpdatedAt) * playerRate : playerTime
    }

    /// Where note `n` is drawn with the playhead at `now` (nil when off screen).
    private func rect(of n: ScoreNote, now: Double, size: CGSize) -> CGRect? {
        guard rows.contains(n.midi) else { return nil }
        let rowH = rowHeight(size)
        let x0 = max(Self.gutter, x(videoTime: videoTime(n.beat), now: now, size: size))
        let x1 = x(videoTime: videoTime(n.beat + max(0.15, n.durationBeats)), now: now, size: size)
        guard x1 > x0, x0 < size.width else { return nil }
        return CGRect(x: x0, y: y(n.midi, size: size) + 1, width: max(3, x1 - x0 - 1), height: max(4, rowH - 2))
    }

    /// The note nearest a tap, if one is within `touchSlop`; otherwise the empty spot's time and key.
    private func target(at point: CGPoint, size: CGSize) -> TapTarget? {
        guard point.x > Self.gutter else { return nil }
        let now = currentTime
        var best: (id: UUID, distance: CGFloat)?
        for item in notes {
            guard let r = rect(of: item.note, now: now, size: size) else { continue }
            let dx = max(r.minX - point.x, 0, point.x - r.maxX)
            let dy = max(r.minY - point.y, 0, point.y - r.maxY)
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance <= Self.touchSlop, distance < (best?.distance ?? .infinity) { best = (item.id, distance) }
        }
        if let best { return .note(best.id) }
        let row = Int(point.y / rowHeight(size))
        let midi = rows.upperBound - row
        guard rows.contains(midi) else { return nil }
        let playheadX = Self.gutter + (size.width - Self.gutter) * Self.playheadFraction
        return .empty(time: now + Double((point.x - playheadX) / Self.pixelsPerSecond), midi: midi)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, now: Double) {
        let isDark = colorScheme == .dark
        let rowH = rowHeight(size)
        let secondsPerBeat = 60 / max(1, tempoBPM)
        let leftTime = now - Double((size.width - Self.gutter) * Self.playheadFraction / Self.pixelsPerSecond)
        let rightTime = now + Double((size.width - Self.gutter) * (1 - Self.playheadFraction) / Self.pixelsPerSecond)

        // Rows: black keys darker, a line under each C.
        for midi in rows {
            let top = y(midi, size: size)
            if KeyboardLayout.isBlackKey(midi) {
                ctx.fill(Path(CGRect(x: Self.gutter, y: top, width: size.width - Self.gutter, height: rowH)),
                         with: .color(Color.primary.opacity(isDark ? 0.08 : 0.05)))
            }
            if midi % 12 == 0 {
                ctx.fill(Path(CGRect(x: Self.gutter, y: top + rowH - 0.5, width: size.width - Self.gutter, height: 1)),
                         with: .color(Color.primary.opacity(0.15)))
            }
        }

        // Bar lines.
        let firstBar = (( (leftTime - offset) / secondsPerBeat) / barLength).rounded(.down) * barLength
        var bar = max(0, firstBar)
        while videoTime(bar) <= rightTime {
            let bx = x(videoTime: videoTime(bar), now: now, size: size)
            if bx >= Self.gutter {
                ctx.fill(Path(CGRect(x: bx - 0.5, y: 0, width: 1, height: size.height)),
                         with: .color(Color.primary.opacity(0.18)))
            }
            bar += barLength
        }

        // Notes.
        for item in notes {
            let n = item.note
            let start = videoTime(n.beat)
            let end = videoTime(n.beat + max(0.15, n.durationBeats))
            guard end >= leftTime, start <= rightTime, let rect = rect(of: n, now: now, size: size) else { continue }
            let playing = start <= now && end > now
            var color = GameColors.color(for: n.hand)
            if !playing { color = color.opacity(0.75) }
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(4, rowH / 3)), with: .color(color))
            if item.id == selection {
                ctx.stroke(Path(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: min(5, rowH / 3)),
                           with: .color(.primary), lineWidth: 3)
            }
            if rect.width > 22, rowH >= 12 {
                let text = ctx.resolve(Text(NoteSpelling.spell(n.midi).letter)
                    .font(.system(size: min(11, rowH * 0.8), weight: .bold, design: .rounded))
                    .foregroundColor(.white))
                ctx.draw(text, at: CGPoint(x: rect.minX + 8, y: rect.midY), anchor: .center)
            }
        }

        // Playhead.
        let px = x(videoTime: now, now: now, size: size)
        ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(.accentColor))
        // Gutter over everything.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: Self.gutter, height: size.height)),
                 with: .color(Color(white: isDark ? 0.12 : 0.96)))
        for midi in rows where midi % 12 == 0 {
            let top = y(midi, size: size)
            let text = ctx.resolve(Text(NoteSpelling.spell(midi).nameWithOctave)
                .font(.system(size: min(11, rowH * 0.9), weight: .semibold, design: .rounded))
                .foregroundColor(.secondary))
            ctx.draw(text, at: CGPoint(x: Self.gutter / 2, y: top + rowH / 2), anchor: .center)
        }
    }

    private func videoTime(_ beat: Double) -> Double { offset + beat * 60 / max(1, tempoBPM) }
}

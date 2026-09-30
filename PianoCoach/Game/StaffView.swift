import PianoCoachCore
import SwiftUI

/// The "Notes" view: the song as sheet music on a grand staff that scrolls from right to left past a
/// playhead — note values, rests, beams, ties and accidentals as on a printed page — to learn reading
/// music. Right-hand notes sit on the treble staff and left-hand notes on the bass staff; notes turn
/// green when they are played.
struct StaffView: View {
    let game: GameController
    let chart: NoteChart

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Read everything the drawing needs here, so the view redraws whenever the game moves.
        let scene = StaffScene(sheet: game.sheetMusic ?? SheetMusic(chart: chart), chart: chart, position: game.position,
                               speed: game.speed, statuses: game.statuses, hitTimes: game.hitTimes, now: game.frameTime,
                               showLetters: game.showLetters, isDark: colorScheme == .dark)
        Canvas { context, size in
            scene.draw(in: &context, size: size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sheet music")
    }
}

/// Where the grand staff sits in a view of a given size.
struct StaffGeometry {
    /// Distance between two staff lines.
    let spacing: CGFloat
    /// y of the treble staff's top line (F5) and the bass staff's top line (A3).
    let trebleTop: CGFloat
    let bassTop: CGFloat
    let left: CGFloat
    let right: CGFloat

    init(size: CGSize, maxSpacing: CGFloat = 32) {
        // Room for the two staves, the gap between them, two ledger lines above and below, and letters.
        // Large enough to read comfortably on an iPad, smaller on a phone.
        let spacing = max(6, min(maxSpacing, size.height / 21, size.width / 30))
        let gap = spacing * (size.height / spacing > 24 ? 4.5 : 3.5)
        let systemHeight = 8 * spacing + gap
        self.spacing = spacing
        trebleTop = max(3 * spacing, (size.height - systemHeight) / 2 - spacing * 0.5)
        bassTop = trebleTop + 4 * spacing + gap
        left = 10
        right = size.width - 10
    }

    var trebleBottom: CGFloat { trebleTop + 4 * spacing }
    var bassBottom: CGFloat { bassTop + 4 * spacing }

    /// y of a staff step (see `SpelledNote.staffStep`) on the treble or bass staff.
    func y(step: Int, treble: Bool) -> CGFloat {
        treble ? trebleBottom - CGFloat(step - NoteSpelling.trebleBottomLine) * spacing / 2
               : bassTop - CGFloat(step - NoteSpelling.bassTopLine) * spacing / 2
    }

    /// Steps that need a ledger line for a note at `step` (lines are on even steps: E4 = 30 is a line).
    static func ledgerSteps(for step: Int, treble: Bool) -> [Int] {
        let (bottomLine, topLine) = treble ? (NoteSpelling.trebleBottomLine, NoteSpelling.trebleBottomLine + 8)
                                           : (NoteSpelling.bassTopLine - 8, NoteSpelling.bassTopLine)
        if step <= bottomLine - 2 {
            return Array(stride(from: bottomLine - 2, through: step, by: -2))
        }
        if step >= topLine + 2 {
            return Array(stride(from: topLine + 2, through: step, by: 2))
        }
        return []
    }
}

/// One frame of the scrolling sheet music.
struct StaffScene {
    let sheet: SheetMusic
    let chart: NoteChart
    let position: Double
    let speed: Double
    let statuses: [NoteStatus]
    let hitTimes: [Int: Double]
    let now: Double
    let showLetters: Bool
    let isDark: Bool

    /// Seconds of music between the playhead and the right edge (fewer when the notes need the room).
    static let visibleSeconds = 4.0

    /// The game's background colour, behind letters.
    var paper: Color {
        isDark ? Color(red: 0.08, green: 0.075, blue: 0.16) : Color(red: 0.945, green: 0.955, blue: 1)
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 40, size.height > 40 else { return }
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        let staff = StaffGeometry(size: size, maxSpacing: 22)
        let s = staff.spacing
        let leftEdge = staff.left + SheetMusicRenderer.startWidth(for: sheet, space: s)
        let playheadX = max(leftEdge + s * 3, size.width * 0.25)
        let byTime = (staff.right - playheadX) / CGFloat(Self.visibleSeconds / chart.secondsPerBeat(atSpeed: speed))
        let pixelsPerBeat = max(byTime, SheetMusicRenderer.minimumPixelsPerBeat(for: sheet, space: s))
        let x: (Double) -> CGFloat = { playheadX + CGFloat($0 - position) * pixelsPerBeat }
        let visible = (position - Double((playheadX - leftEdge) / pixelsPerBeat))...(position + Double((size.width - playheadX) / pixelsPerBeat))

        // Playhead glow, behind everything.
        let glowWidth = s * 3
        context.fill(Path(CGRect(x: playheadX - glowWidth / 2, y: staff.trebleTop - 2 * s, width: glowWidth,
                                 height: staff.bassBottom - staff.trebleTop + 4 * s)),
                     with: .linearGradient(Gradient(colors: [Color.accentColor.opacity(0), Color.accentColor.opacity(0.16),
                                                             Color.accentColor.opacity(0)]),
                                           startPoint: CGPoint(x: playheadX - glowWidth / 2, y: 0),
                                           endPoint: CGPoint(x: playheadX + glowWidth / 2, y: 0)))

        let upcoming = nextNoteTime
        let renderer = SheetMusicRenderer(
            sheet: sheet, staff: staff, x: x, visibleBeats: visible, position: position, showLetters: showLetters,
            isDark: isDark, paper: paper,
            noteColor: { id in
                guard id < statuses.count, id < chart.notes.count else { return nil }
                switch statuses[id] {
                case .pending:
                    return upcoming.map { abs(chart.notes[id].time - $0) < 1e-3 } == true ? Color.accentColor : nil
                case .hit: return GameColors.hit
                case .missed: return GameColors.wrong.opacity(0.8)
                case .notRequired: return Color.gray.opacity(0.45)
                }
            },
            glow: { id in
                guard let hit = hitTimes[id], now - hit >= 0, now - hit < 0.7 else { return nil }
                return 1 - (now - hit) / 0.7
            })
        renderer.draw(in: &context, size: size)

        // The playhead itself, on top.
        context.fill(Path(roundedRect: CGRect(x: playheadX - 1.5, y: staff.trebleTop - 1.5 * s, width: 3,
                                              height: staff.bassBottom - staff.trebleTop + 3 * s),
                          cornerRadius: 1.5),
                     with: .color(Color.accentColor.opacity(0.85)))
    }

    /// Start time of the next notes to play (they are shown in the accent colour).
    private var nextNoteTime: Double? {
        for note in chart.notes where note.time >= position - 0.05 {
            if note.id < statuses.count, statuses[note.id] == .pending { return note.time }
        }
        return nil
    }
}

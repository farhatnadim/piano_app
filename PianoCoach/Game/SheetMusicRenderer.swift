import PianoCoachCore
import SwiftUI

/// Draws `SheetMusic` on a grand staff that scrolls past a playhead, the way printed music looks: clefs
/// and the key and time signatures at the left, then noteheads, stems, flags, beams, dots, ties,
/// accidentals, ledger lines, rests and bar lines. Every note is drawn at `x(beat)` (the centre of its
/// head), so it reaches the playhead exactly when it's due.
struct SheetMusicRenderer {
    let sheet: SheetMusic
    let staff: StaffGeometry
    /// Where a beat is drawn.
    let x: (Double) -> CGFloat
    /// Beats in view (a little more is fine).
    let visibleBeats: ClosedRange<Double>
    /// The beat at the playhead (the time signature at the left is the one in force there).
    let position: Double
    let showLetters: Bool
    let isDark: Bool
    /// The background, behind letters and where notes slide under the clefs.
    var paper: Color
    /// Colour of a note by chart note id; nil: ink.
    var noteColor: (Int) -> Color? = { _ in nil }
    /// A glow behind a note just played, 0...1, by chart note id.
    var glow: (Int) -> Double? = { _ in nil }
    /// Chart note ids to mark as selected (the note editor).
    var selected: Set<Int> = []

    // Engraving sizes in staff spaces (Bravura's engraving defaults).
    static let stemThickness: CGFloat = 0.12
    static let stemLength: CGFloat = 3.5
    static let beamThickness: CGFloat = 0.5
    static let beamGap: CGFloat = 0.25
    static let ledgerExtension: CGFloat = 0.4
    static let staffLineThickness: CGFloat = 0.13

    private var font: MusicFont { .shared }
    private var ink: Color { Color.primary.opacity(0.85) }

    // MARK: - Sizes

    /// Width of the clefs and signatures at the left, in points.
    static func startWidth(for sheet: SheetMusic, space s: CGFloat) -> CGFloat {
        let keyCount = CGFloat(min(7, abs(sheet.keyFifths)))
        return s * (0.5 + 2.9 + 0.8 + keyCount * 1.05 + (keyCount > 0 ? 0.6 : 0) + 2.1 + 1.2)
    }

    /// The fewest points per beat that keep the song's shortest notes apart.
    static func minimumPixelsPerBeat(for sheet: SheetMusic, space s: CGFloat) -> CGFloat {
        let shortest = sheet.events.lazy.filter { !$0.isRest }.map(\.value.beats).min() ?? 1
        return s * 2.1 / CGFloat(max(0.25, shortest))
    }

    // MARK: - Drawing

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let s = staff.spacing
        let leftEdge = staff.left + Self.startWidth(for: sheet, space: s)
        drawStaffLines(in: &context, from: staff.left, to: staff.right)

        var scrolling = context
        scrolling.clip(to: Path(CGRect(x: leftEdge, y: 0, width: max(0, size.width - leftEdge), height: size.height)))
        drawBarLines(in: &scrolling)
        drawMusic(in: &scrolling)

        // Notes slide under the clefs: fade them out over a short band, keeping the staff lines.
        let band = CGRect(x: leftEdge, y: 0, width: s * 1.6, height: size.height)
        context.fill(Path(band), with: .linearGradient(Gradient(colors: [paper, paper.opacity(0)]),
                                                       startPoint: CGPoint(x: band.minX, y: 0),
                                                       endPoint: CGPoint(x: band.maxX, y: 0)))
        context.fill(Path(CGRect(x: 0, y: 0, width: leftEdge, height: size.height)), with: .color(paper))
        drawStaffLines(in: &context, from: staff.left, to: band.maxX)
        drawSystemStart(in: &context)
    }

    private func drawStaffLines(in context: inout GraphicsContext, from x0: CGFloat, to x1: CGFloat) {
        let s = staff.spacing
        let thickness = max(1, Self.staffLineThickness * s)
        for top in [staff.trebleTop, staff.bassTop] {
            for i in 0..<5 {
                let y = top + CGFloat(i) * s
                context.fill(Path(CGRect(x: x0, y: y - thickness / 2, width: x1 - x0, height: thickness)),
                             with: .color(ink.opacity(0.8)))
            }
        }
    }

    /// The line joining the staves, the clefs, the key signature and the time signature.
    private func drawSystemStart(in context: inout GraphicsContext) {
        let s = staff.spacing
        context.fill(Path(CGRect(x: staff.left, y: staff.trebleTop, width: max(1.5, 0.16 * s),
                                 height: staff.bassBottom - staff.trebleTop)), with: .color(ink))
        let clefX = staff.left + 0.5 * s
        if let g = font.shape(.gClef) {
            context.fill(MusicFont.path(g, origin: CGPoint(x: clefX, y: staff.y(step: 32, treble: true)), space: s),
                         with: .color(ink))
        }
        if let f = font.shape(.fClef) {
            context.fill(MusicFont.path(f, origin: CGPoint(x: clefX, y: staff.y(step: 24, treble: false)), space: s),
                         with: .color(ink))
        }
        // Key signature: sharps F C G D A E B, flats B E A D G C F, at their places on each staff.
        var keyX = clefX + 2.9 * s + 0.4 * s
        let count = min(7, abs(sheet.keyFifths))
        if count > 0, let sign = font.shape(sheet.keyFifths > 0 ? .accidentalSharp : .accidentalFlat) {
            let trebleSteps = sheet.keyFifths > 0 ? [38, 35, 39, 36, 33, 37, 34] : [34, 37, 33, 36, 32, 35, 31]
            for i in 0..<count {
                for treble in [true, false] {
                    let step = trebleSteps[i] - (treble ? 0 : 14)
                    context.fill(MusicFont.path(sign, origin: CGPoint(x: keyX, y: staff.y(step: step, treble: treble)), space: s),
                                 with: .color(ink))
                }
                keyX += (sign.bounds.width + 0.15) * s
            }
            keyX += 0.45 * s
        }
        // Time signature in force at the playhead.
        let signature = sheet.measureIndex(atBeat: position).map { sheet.measures[$0].timeSignature } ?? .common
        let columnCenter = keyX + 1.0 * s
        for top in [staff.trebleTop, staff.bassTop] {
            drawNumber(signature.beats, centerX: columnCenter, centerY: top + s, in: &context)
            drawNumber(signature.beatType, centerX: columnCenter, centerY: top + 3 * s, in: &context)
        }
    }

    private func drawNumber(_ number: Int, centerX: CGFloat, centerY: CGFloat, in context: inout GraphicsContext) {
        let s = staff.spacing
        let digits = String(number).compactMap { $0.wholeNumberValue }.compactMap { font.timeSignatureDigit($0) }
        let total = digits.reduce(0) { $0 + $1.bounds.width } * s
        var x = centerX - total / 2
        for digit in digits {
            let origin = CGPoint(x: x - digit.bounds.minX * s, y: centerY + digit.bounds.midY * s)
            context.fill(MusicFont.path(digit, origin: origin, space: s), with: .color(ink))
            x += digit.bounds.width * s
        }
    }

    // MARK: Bar lines

    private func drawBarLines(in context: inout GraphicsContext) {
        let s = staff.spacing
        let thickness = max(1, 0.16 * s)
        for (i, measure) in sheet.measures.enumerated() {
            let isEnd = i == sheet.measures.count - 1
            for (beat, final) in [(measure.startBeat, false), (measure.endBeat, isEnd)] where beat > sheet.measures[0].startBeat + 1e-9 {
                guard visibleBeats.contains(beat) else { continue }
                if !final && beat == measure.endBeat { continue }   // drawn as the next measure's start
                let x = barX(at: beat)
                context.fill(Path(CGRect(x: x - thickness / 2, y: staff.trebleTop, width: thickness,
                                         height: staff.bassBottom - staff.trebleTop)), with: .color(ink.opacity(0.7)))
                if final {
                    context.fill(Path(CGRect(x: x + 0.5 * s, y: staff.trebleTop, width: 0.5 * s,
                                             height: staff.bassBottom - staff.trebleTop)), with: .color(ink))
                }
            }
        }
    }

    /// A bar line sits a little before its downbeat (clear of the notes and their accidentals), but no
    /// further than halfway back to the note before.
    private func barX(at beat: Double) -> CGFloat {
        let s = staff.spacing
        let downbeat = x(beat)
        let range = sheet.eventIndices(inBeats: (beat - 8)...(beat + 1e-6))
        var previous: CGFloat?
        var accidentals = 0
        for i in range {
            let event = sheet.events[i]
            if abs(event.gridBeat - beat) < 1e-6 {
                accidentals = max(accidentals, event.heads.filter { $0.accidental != nil }.count > 0 ? 1 : 0)
            } else if event.gridBeat < beat {
                previous = max(previous ?? -.infinity, x(event.beat))
            }
        }
        let wanted = s * (1.5 + CGFloat(accidentals) * 1.2)
        let room = previous.map { (downbeat - $0) / 2 } ?? .infinity
        return downbeat - min(wanted, room)
    }

    // MARK: Notes and rests

    private struct HeadPlace {
        var head: SheetMusic.Head
        var center: CGPoint
        var width: CGFloat
    }

    private struct Layout {
        var heads: [HeadPlace]
        var up: Bool
        var stemX: CGFloat
        /// Where the stem leaves the far notehead, and the head nearest the stem's end.
        var stemFrom: CGFloat
        var nearY: CGFloat
        var stemEnd: CGFloat
        var color: Color
    }

    private func headShape(for value: NoteValue) -> MusicFont.Shape? {
        font.shape(value.base == 1 ? .noteheadWhole : value.base == 2 ? .noteheadHalf : .noteheadBlack)
    }

    private func color(of event: SheetMusic.Event) -> Color {
        let colors = event.heads.compactMap { $0.chartNoteID }.map { noteColor($0) }
        if let first = colors.first, colors.allSatisfy({ $0 == first }), let color = first { return color }
        return ink
    }

    private func layout(of event: SheetMusic.Event) -> Layout? {
        guard !event.isRest, let shape = headShape(for: event.value) else { return nil }
        let s = staff.spacing
        let treble = event.clef == .treble
        let width = shape.bounds.width * s
        let cx = x(event.beat)
        var heads = event.heads.sorted { $0.staffStep < $1.staffStep }.map {
            HeadPlace(head: $0, center: CGPoint(x: cx, y: staff.y(step: $0.staffStep, treble: treble)), width: width)
        }
        // Notes a step apart in a chord sit on opposite sides of the stem.
        let shift = width - Self.stemThickness * s
        if event.stemUp || !event.value.hasStem {
            var previousDisplaced = false
            for i in heads.indices.dropFirst() where heads[i].head.staffStep - heads[i - 1].head.staffStep == 1 && !previousDisplaced {
                heads[i].center.x += shift
                previousDisplaced = true
            }
        } else {
            var previousDisplaced = false
            for i in heads.indices.reversed().dropFirst() where heads[i + 1].head.staffStep - heads[i].head.staffStep == 1 && !previousDisplaced {
                heads[i].center.x -= shift
                previousDisplaced = true
            }
        }
        let lowest = heads.first!.center.y   // lowest pitch: largest y
        let highest = heads.last!.center.y
        let middle = (treble ? staff.trebleTop : staff.bassTop) + 2 * s
        let up = event.stemUp
        let stemX = up ? cx - width / 2 + width - Self.stemThickness * s / 2 : cx - width / 2 + Self.stemThickness * s / 2
        let extra: CGFloat = event.value.flags >= 2 ? 0.6 * s : 0
        var end = up ? highest - Self.stemLength * s - extra : lowest + Self.stemLength * s + extra
        if up && end > middle { end = middle }
        if !up && end < middle { end = middle }
        return Layout(heads: heads, up: up, stemX: stemX,
                      stemFrom: up ? lowest - 0.168 * s : highest + 0.168 * s,
                      nearY: up ? highest : lowest, stemEnd: end, color: color(of: event))
    }

    private func drawMusic(in context: inout GraphicsContext) {
        let s = staff.spacing
        let range = sheet.eventIndices(inBeats: (visibleBeats.lowerBound - 4)...(visibleBeats.upperBound + 1))
        var layouts: [Int: Layout] = [:]
        func layoutFor(_ i: Int) -> Layout? {
            if let cached = layouts[i] { return cached }
            let made = layout(of: sheet.events[i])
            layouts[i] = made
            return made
        }
        // Beams decide their stems' ends.
        var beamIDs = Set<Int>()
        for i in range { if let beam = sheet.events[i].beam { beamIDs.insert(beam) } }
        var beamLines: [Int: (x0: CGFloat, y0: CGFloat, slope: CGFloat)] = [:]
        for beam in beamIDs {
            let members = sheet.beams[beam]
            let placed = members.compactMap { i in layoutFor(i).map { (i, $0) } }
            guard placed.count >= 2, let first = placed.first?.1, let last = placed.last?.1 else { continue }
            let up = first.up
            let natural = { (l: Layout) -> CGFloat in up ? l.nearY - Self.stemLength * s : l.nearY + Self.stemLength * s }
            let dx = last.stemX - first.stemX
            var slope = dx > 0 ? (natural(last) - natural(first)) / dx : 0
            let maxRise = 1.0 * s
            if abs(slope * dx) > maxRise { slope = (slope > 0 ? maxRise : -maxRise) / dx }
            var y0 = natural(first)
            let hasSixteenths = members.contains { sheet.events[$0].value.flags >= 2 }
            let minimum = (hasSixteenths ? 3.25 : 3.0) * s
            var push: CGFloat = 0
            for (_, l) in placed {
                let y = y0 + slope * (l.stemX - first.stemX)
                push = max(push, up ? y - (l.nearY - minimum) : (l.nearY + minimum) - y)
            }
            y0 += up ? -push : push
            beamLines[beam] = (first.stemX, y0, slope)
            for (i, l) in placed {
                var updated = l
                updated.stemEnd = y0 + slope * (l.stemX - first.stemX)
                layouts[i] = updated
            }
        }

        for i in range {
            let event = sheet.events[i]
            if event.isRest {
                drawRest(event, in: &context)
                continue
            }
            guard let l = layoutFor(i) else { continue }
            drawNote(event, layout: l, beamed: event.beam.flatMap { beamLines[$0] } != nil, in: &context)
        }
        for beam in beamIDs {
            guard let line = beamLines[beam] else { continue }
            drawBeam(sheet.beams[beam], line: line, layouts: layouts, in: &context)
        }
        for i in range {
            guard let target = sheet.events[i].tiedTo, let from = layoutFor(i), let to = layoutFor(target) else { continue }
            drawTies(from: from, to: to, in: &context)
        }
    }

    private func drawNote(_ event: SheetMusic.Event, layout l: Layout, beamed: Bool, in context: inout GraphicsContext) {
        let s = staff.spacing
        let treble = event.clef == .treble
        guard let head = headShape(for: event.value) else { return }
        // Selection and glow behind the notes.
        for place in l.heads {
            guard let id = place.head.chartNoteID else { continue }
            if selected.contains(id) {
                let box = CGRect(x: place.center.x - place.width / 2 - 0.45 * s, y: place.center.y - 0.95 * s,
                                 width: place.width + 0.9 * s, height: 1.9 * s)
                context.fill(Path(roundedRect: box, cornerRadius: 0.5 * s), with: .color(Color.accentColor.opacity(0.25)))
                context.stroke(Path(roundedRect: box, cornerRadius: 0.5 * s), with: .color(.accentColor), lineWidth: 2)
            }
            if let strength = glow(id), strength > 0 {
                let radius = s * (1.2 + 1.6 * (1 - strength))
                context.fill(Path(ellipseIn: CGRect(x: place.center.x - radius, y: place.center.y - radius,
                                                    width: 2 * radius, height: 2 * radius)),
                             with: .radialGradient(Gradient(colors: [GameColors.hit.opacity(0.55 * strength), GameColors.hit.opacity(0)]),
                                                   center: place.center, startRadius: 0, endRadius: radius))
            }
        }
        // Ledger lines.
        let ledgerThickness = max(1, 0.16 * s)
        for place in l.heads {
            for step in StaffGeometry.ledgerSteps(for: place.head.staffStep, treble: treble) {
                let y = staff.y(step: step, treble: treble)
                let half = place.width / 2 + Self.ledgerExtension * s
                context.fill(Path(CGRect(x: place.center.x - half, y: y - ledgerThickness / 2, width: 2 * half, height: ledgerThickness)),
                             with: .color(ink))
            }
        }
        // Heads.
        for place in l.heads {
            let color = place.head.chartNoteID.flatMap { noteColor($0) } ?? ink
            let origin = CGPoint(x: place.center.x - place.width / 2 - head.bounds.minX * s, y: place.center.y)
            context.fill(MusicFont.path(head, origin: origin, space: s), with: .color(color))
        }
        // Stem and flag.
        if event.value.hasStem {
            let top = min(l.stemFrom, l.stemEnd), bottom = max(l.stemFrom, l.stemEnd)
            context.fill(Path(CGRect(x: l.stemX - Self.stemThickness * s / 2, y: top, width: Self.stemThickness * s,
                                     height: bottom - top)), with: .color(l.color))
            if !beamed, event.value.flags > 0 {
                let glyph: MusicFont.Glyph = event.value.flags >= 2 ? (l.up ? .flag16thUp : .flag16thDown)
                                                                    : (l.up ? .flag8thUp : .flag8thDown)
                if let flag = font.shape(glyph) {
                    context.fill(MusicFont.path(flag, origin: CGPoint(x: l.stemX - Self.stemThickness * s / 2, y: l.stemEnd), space: s),
                                 with: .color(l.color))
                }
            }
        }
        // Dots, in the space above a note on a line.
        if event.value.dotted, let dot = font.shape(.augmentationDot) {
            let right = l.heads.map { $0.center.x + $0.width / 2 }.max() ?? 0
            for place in l.heads {
                let onLine = place.head.staffStep % 2 == 0
                let y = place.center.y - (onLine ? 0.5 * s : 0)
                context.fill(MusicFont.path(dot, origin: CGPoint(x: right + 0.3 * s, y: y), space: s), with: .color(l.color))
            }
        }
        // Accidentals, in columns so they don't collide.
        let left = (l.heads.map { $0.center.x - $0.width / 2 }.min() ?? 0) - 0.18 * s
        var placed: [(step: Int, column: Int)] = []
        for place in l.heads.reversed() {
            guard let accidental = place.head.accidental else { continue }
            let glyph: MusicFont.Glyph = accidental == .sharp ? .accidentalSharp : accidental == .flat ? .accidentalFlat : .accidentalNatural
            guard let sign = font.shape(glyph) else { continue }
            var column = 0
            while placed.contains(where: { $0.column == column && abs($0.step - place.head.staffStep) < 6 }) { column += 1 }
            placed.append((place.head.staffStep, column))
            let right = left - CGFloat(column) * 1.15 * s
            let color = place.head.chartNoteID.flatMap { noteColor($0) } ?? ink
            context.fill(MusicFont.path(sign, origin: CGPoint(x: right - sign.bounds.maxX * s, y: place.center.y), space: s),
                         with: .color(color))
        }
        if showLetters { drawLetters(for: l, event: event, in: &context) }
    }

    /// Letter names on the side away from the stem: below the notes when the stem points up, above when
    /// it points down; a chord's letters stacked in the order of its notes.
    private func drawLetters(for l: Layout, event: SheetMusic.Event, in context: inout GraphicsContext) {
        let s = staff.spacing
        let treble = event.clef == .treble
        let below = l.up || !event.value.hasStem
        let size = max(9, s * (l.heads.count > 1 ? 0.8 : 0.95))
        let lineHeight = size * 1.15
        let ordered = l.heads.reversed()   // highest first, as the chord reads from top to bottom
        let x = l.heads.map(\.center.x).reduce(0, +) / CGFloat(l.heads.count)
        let lowestLedger = StaffGeometry.ledgerSteps(for: l.heads.first!.head.staffStep, treble: treble).count
        let highestLedger = StaffGeometry.ledgerSteps(for: l.heads.last!.head.staffStep, treble: treble).count
        var y = below ? l.heads.first!.center.y + 0.75 * s + (lowestLedger > 0 ? 0.2 * s : 0)
                      : l.heads.last!.center.y - 0.75 * s - CGFloat(ordered.count) * lineHeight - (highestLedger > 0 ? 0.2 * s : 0)
        for place in ordered {
            var text = context.resolve(Text(place.head.spelled.name).font(.system(size: size, weight: .bold, design: .rounded)))
            let color = place.head.chartNoteID.flatMap { noteColor($0) }
            text.shading = .color(color ?? Color.secondary)
            let measured = text.measure(in: CGSize(width: 200, height: 200))
            let origin = CGPoint(x: x - measured.width / 2, y: y)
            let patch = CGRect(origin: origin, size: measured).insetBy(dx: -0.12 * s, dy: -0.02 * s)
            context.fill(Path(roundedRect: patch, cornerRadius: 0.2 * s), with: .color(paper))
            context.draw(text, at: origin, anchor: .topLeading)
            y += lineHeight
        }
    }

    private func drawBeam(_ members: [Int], line: (x0: CGFloat, y0: CGFloat, slope: CGFloat), layouts: [Int: Layout],
                          in context: inout GraphicsContext) {
        let s = staff.spacing
        let placed = members.compactMap { i in layouts[i].map { (event: sheet.events[i], layout: $0) } }
        guard let first = placed.first, let last = placed.last else { return }
        let up = first.layout.up
        let thickness = Self.beamThickness * s
        let color = placed.allSatisfy({ $0.layout.color == first.layout.color }) ? first.layout.color : ink
        func y(_ x: CGFloat, level: Int) -> CGFloat {
            line.y0 + line.slope * (x - line.x0) + CGFloat(level) * (Self.beamThickness + Self.beamGap) * s * (up ? 1 : -1)
        }
        func bar(from a: CGFloat, to b: CGFloat, level: Int) {
            let ya = y(a, level: level), yb = y(b, level: level)
            let t = up ? thickness : -thickness
            var path = Path()
            path.move(to: CGPoint(x: a, y: ya))
            path.addLine(to: CGPoint(x: b, y: yb))
            path.addLine(to: CGPoint(x: b, y: yb + t))
            path.addLine(to: CGPoint(x: a, y: ya + t))
            path.closeSubpath()
            context.fill(path, with: .color(color))
        }
        let half = Self.stemThickness * s / 2
        bar(from: first.layout.stemX - half, to: last.layout.stemX + half, level: 0)
        // Sixteenths: a second beam between neighbours, or a short one pointing at the neighbour.
        for (k, item) in placed.enumerated() where item.event.value.flags >= 2 {
            let nextIsShort = k + 1 < placed.count && placed[k + 1].event.value.flags >= 2
            let previousIsShort = k > 0 && placed[k - 1].event.value.flags >= 2
            if nextIsShort {
                bar(from: item.layout.stemX - half, to: placed[k + 1].layout.stemX + half, level: 1)
            } else if !previousIsShort {
                let stub = 1.1 * s
                if k + 1 < placed.count {
                    bar(from: item.layout.stemX - half, to: item.layout.stemX + stub, level: 1)
                } else {
                    bar(from: item.layout.stemX - stub, to: item.layout.stemX + half, level: 1)
                }
            }
        }
    }

    private func drawTies(from a: Layout, to b: Layout, in context: inout GraphicsContext) {
        let s = staff.spacing
        for start in a.heads {
            guard let end = b.heads.first(where: { $0.head.midi == start.head.midi }) else { continue }
            let x0 = start.center.x + start.width / 2 + 0.12 * s
            let x1 = end.center.x - end.width / 2 - 0.12 * s
            guard x1 - x0 > 0.5 * s else { continue }
            let below = a.up
            let direction: CGFloat = below ? 1 : -1
            let y = start.center.y + direction * 0.6 * s
            let height = min(1.0 * s, 0.25 * s + 0.08 * (x1 - x0)) * direction
            let mid = CGPoint(x: (x0 + x1) / 2, y: y + height)
            var path = Path()
            path.move(to: CGPoint(x: x0, y: y))
            path.addQuadCurve(to: CGPoint(x: x1, y: y), control: mid)
            path.addQuadCurve(to: CGPoint(x: x0, y: y), control: CGPoint(x: mid.x, y: mid.y - direction * 0.22 * s))
            path.closeSubpath()
            context.fill(path, with: .color(start.head.chartNoteID.flatMap { noteColor($0) } ?? ink))
        }
    }

    private func drawRest(_ event: SheetMusic.Event, in context: inout GraphicsContext) {
        let s = staff.spacing
        let top = event.clef == .treble ? staff.trebleTop : staff.bassTop
        let middle = top + 2 * s
        if event.isMeasureRest {
            guard let rest = font.shape(.restWhole) else { return }
            let measure = sheet.measures[event.measureIndex]
            let from = barX(at: measure.startBeat), to = barX(at: measure.endBeat)
            let cx = measure.startBeat <= sheet.measures[0].startBeat + 1e-9 ? (x(measure.startBeat) + to) / 2 : (from + to) / 2
            let origin = CGPoint(x: cx - rest.bounds.midX * s, y: top + s + rest.bounds.maxY * s)
            context.fill(MusicFont.path(rest, origin: origin, space: s), with: .color(ink.opacity(0.75)))
            return
        }
        let glyph: MusicFont.Glyph
        switch event.value.base {
        case 1: glyph = .restWhole
        case 2: glyph = .restHalf
        case 4: glyph = .restQuarter
        case 8: glyph = .rest8th
        default: glyph = .rest16th
        }
        guard let rest = font.shape(glyph) else { return }
        let cx = x(event.beat)
        let y: CGFloat
        switch event.value.base {
        case 1: y = top + s + rest.bounds.maxY * s                 // hangs from the fourth line
        case 2: y = middle + rest.bounds.minY * s                   // sits on the middle line
        case 16: y = middle + 0.5 * s + rest.bounds.midY * s
        default: y = middle + rest.bounds.midY * s
        }
        context.fill(MusicFont.path(rest, origin: CGPoint(x: cx - rest.bounds.midX * s, y: y), space: s),
                     with: .color(ink.opacity(0.75)))
        if event.value.dotted, let dot = font.shape(.augmentationDot) {
            context.fill(MusicFont.path(dot, origin: CGPoint(x: cx + rest.bounds.width * s / 2 + 0.3 * s, y: top + 1.5 * s), space: s),
                         with: .color(ink.opacity(0.75)))
        }
    }

    // MARK: - Finding notes

    /// Where each visible note's head is drawn, with its chart note id (for tapping notes).
    func headCenters() -> [(id: Int, center: CGPoint)] {
        var result: [(Int, CGPoint)] = []
        for i in sheet.eventIndices(inBeats: (visibleBeats.lowerBound - 1)...(visibleBeats.upperBound + 1)) {
            let event = sheet.events[i]
            let treble = event.clef == .treble
            for head in event.heads {
                guard let id = head.chartNoteID else { continue }
                result.append((id, CGPoint(x: x(event.beat), y: staff.y(step: head.staffStep, treble: treble))))
            }
        }
        return result
    }
}

import PianoCoachCore
import SwiftUI

/// Cuts the beginning or the end off a learned song — a video's spoken introduction, a flourish, the
/// applause — so the game only asks for the song itself.
///
/// The whole song is drawn as a piano roll; two sliders choose where it starts and ends, snapping to the
/// song's measures, and the notes outside are greyed out. "Hear the start" plays a few notes from the
/// chosen start so the cut can be checked by ear before it is kept.
struct TrimSongView: View {
    @Environment(AppModel.self) private var model
    let chart: NoteChart

    /// Chosen range, in beats.
    @State private var start: Double
    @State private var end: Double
    @State private var preview: Task<Void, Never>?

    /// Points the sliders snap to: the song's measures, or whole beats when it has no bar lines.
    private let stops: [Double]

    init(chart: NoteChart) {
        self.chart = chart
        let length = chart.notes.map(\.end).max() ?? 0
        var stops = chart.barLines.filter { $0 > 0 && $0 < length }
        if stops.isEmpty { stops = stride(from: 1.0, to: length, by: 1).map { $0 } }
        self.stops = [0] + stops + [length]
        _start = State(initialValue: 0)
        _end = State(initialValue: length)
    }

    private var keptCount: Int {
        chart.notes.filter { $0.time >= start - 1e-9 && $0.time < end - 1e-9 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Slide the handles so only the song is left — no talking or noise before it, nothing after it.")
                .foregroundStyle(.secondary)
            PianoRoll(chart: chart, start: start, end: end)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(spacing: 14) {
                slider("Start", value: $start, range: 0...max(0, end - stopGap), systemImage: "backward.end")
                slider("End", value: $end, range: min(stops.last ?? 0, start + stopGap)...(stops.last ?? 0), systemImage: "forward.end")
            }
            HStack {
                Text("\(keptCount) of \(chart.notes.count) notes stay")
                    .font(.headline)
                    .contentTransition(.numericText())
                Spacer()
                Button {
                    preview == nil ? playPreview() : stopPreview()
                } label: {
                    Label(preview == nil ? "Hear the start" : "Stop", systemImage: preview == nil ? "play.fill" : "stop.fill")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: 640)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: keptCount)
        .navigationTitle("Trim the song")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.showTrimScreen = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Keep") {
                    model.trimSong(fromBeat: start, toBeat: end)
                    model.showTrimScreen = false
                }
                .disabled(keptCount == 0 || (start == 0 && end == stops.last))
            }
        }
        .onDisappear { stopPreview() }
    }

    /// The smallest gap the sliders keep between them: one stop.
    private var stopGap: Double {
        stops.count > 1 ? stops[1] - stops[0] : 1
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
                .frame(width: 84, alignment: .leading)
            Slider(value: Binding(get: { value.wrappedValue },
                                  set: { value.wrappedValue = snap($0, to: range) }),
                   in: range.lowerBound...max(range.lowerBound + 0.001, range.upperBound))
            Text(label(forBeat: value.wrappedValue))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
        }
    }

    /// The nearest stop inside `range`.
    private func snap(_ beat: Double, to range: ClosedRange<Double>) -> Double {
        let candidates = stops.filter { range.contains($0) }
        return candidates.min { abs($0 - beat) < abs($1 - beat) } ?? min(max(beat, range.lowerBound), range.upperBound)
    }

    /// "Measure 3" when the stop is a bar line, else "12.0 s".
    private func label(forBeat beat: Double) -> String {
        if let index = chart.barLines.firstIndex(where: { abs($0 - beat) < 1e-6 }) {
            return "Measure \(index + 1)"
        }
        if abs(beat - (stops.last ?? -1)) < 1e-6 { return "The end" }
        return String(format: "%.1f s", beat * chart.secondsPerBeat(atSpeed: 1))
    }

    // MARK: - Preview

    /// Plays the notes of the first two measures (or four seconds) from `start` on the built-in piano.
    private func playPreview() {
        let seconds = chart.secondsPerBeat(atSpeed: 1)
        let until = min(end, start + max(4 / seconds, 2 * stopGap))
        let notes = chart.notes.filter { $0.time >= start - 1e-9 && $0.time < until }
        guard !notes.isEmpty, (try? model.sound.start()) != nil else { return }
        let sound = model.sound
        let origin = start
        preview = Task { @MainActor in
            var events: [(at: Double, midi: Int, on: Bool, velocity: Float)] = []
            for n in notes {
                events.append(((n.time - origin) * seconds, n.midi, true, Float(n.velocity ?? 0.7)))
                events.append((min(until - origin, n.end - origin) * seconds, n.midi, false, 0))
            }
            events.sort { $0.at < $1.at }
            let began = MonotonicClock.now()
            for event in events {
                let wait = event.at - (MonotonicClock.now() - began)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                guard !Task.isCancelled else { break }
                event.on ? sound.noteOn(event.midi, velocity: event.velocity) : sound.noteOff(event.midi)
            }
            sound.allNotesOff()
            preview = nil
        }
    }

    private func stopPreview() {
        preview?.cancel()
        preview = nil
        model.sound.allNotesOff()
    }
}

/// The song's notes as bars on a beat × pitch grid, with the part outside `start...end` dimmed.
private struct PianoRoll: View {
    let chart: NoteChart
    let start: Double
    let end: Double

    var body: some View {
        Canvas { context, size in
            let length = max(1, chart.notes.map(\.end).max() ?? 1)
            let lowest = Double(chart.notes.map(\.midi).min() ?? 48) - 2
            let highest = Double(chart.notes.map(\.midi).max() ?? 72) + 2
            let x: (Double) -> CGFloat = { CGFloat($0 / length) * size.width }
            let y: (Int) -> CGFloat = { CGFloat(1 - (Double($0) - lowest) / (highest - lowest)) * size.height }
            let rowHeight = max(2, size.height / CGFloat(highest - lowest))

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.08)))
            for bar in chart.barLines where bar > 0 && bar < length {
                let line = Path { $0.move(to: CGPoint(x: x(bar), y: 0)); $0.addLine(to: CGPoint(x: x(bar), y: size.height)) }
                context.stroke(line, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
            }
            for note in chart.notes {
                let inside = note.time >= start - 1e-9 && note.time < end - 1e-9
                let rect = CGRect(x: x(note.time), y: y(note.midi) - rowHeight / 2,
                                  width: max(2, x(note.end) - x(note.time) - 1), height: rowHeight - 1)
                let color = inside ? GameColors.color(for: note.hand) : Color.secondary.opacity(0.35)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
            // Shade the cut parts and mark the handles.
            let cuts = [CGRect(x: 0, y: 0, width: x(start), height: size.height),
                        CGRect(x: x(end), y: 0, width: size.width - x(end), height: size.height)]
            for cut in cuts where cut.width > 0 {
                context.fill(Path(cut), with: .color(.black.opacity(0.18)))
            }
            for edge in [start, end] where edge > 0 && edge < length {
                let line = Path { $0.move(to: CGPoint(x: x(edge), y: 0)); $0.addLine(to: CGPoint(x: x(edge), y: size.height)) }
                context.stroke(line, with: .color(.accentColor), lineWidth: 2)
            }
        }
        .accessibilityLabel("The song's notes, with the part to keep highlighted")
    }
}

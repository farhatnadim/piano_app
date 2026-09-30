import Foundation

/// Writes a `Score` as a Standard MIDI File, so a song worked out from a recording can be saved, shared
/// and opened in other music apps, and read back with `MIDIFileParser` without losing hands or loudness.
///
/// Layout (format 1, 480 ticks per quarter note):
/// - track 1, the conductor: the title as track name, the tempo, time signatures and the key signature;
/// - track 2, "Right hand": channel 1, acoustic grand piano;
/// - track 3, "Left hand": channel 2, acoustic grand piano.
///
/// Both hand tracks are always written, even when one is empty, so the layout is predictable.
public enum MIDIFileWriter {
    public static let ticksPerQuarter = 480
    /// Note-on velocity for notes whose `velocity` is unknown.
    public static let defaultVelocity = 80

    /// The file's bytes. `isMinor` only affects the key-signature event (the score stores just the
    /// number of sharps or flats).
    public static func data(for score: Score, isMinor: Bool = false) -> Data {
        let q = Double(ticksPerQuarter)
        // Clamped before converting: Int(_:) traps on NaN, infinity and values beyond Int's range.
        func tick(_ beat: Double) -> Int {
            let t = (beat * q).rounded()
            return t.isNaN ? 0 : Int(max(0, min(t, 1e15)))
        }

        var notes: [(on: Int, off: Int, midi: Int, velocity: Int, hand: Hand)] = []
        for n in score.notes {
            let on = tick(n.beat)
            let off = max(on + 1, tick(n.beat + n.durationBeats))
            let velocity = n.velocity.flatMap { $0.isFinite ? Int((max(0, min(1, $0)) * 127).rounded()) : nil } ?? defaultVelocity
            notes.append((on, off, max(0, min(127, n.midi)), max(1, min(127, velocity)), n.hand))
        }
        let lastMeasureEnd = score.measures.last.map { tick($0.endBeat) } ?? 0
        let endTick = max(lastMeasureEnd, notes.map(\.off).max() ?? 0)

        var conductor = TrackBuilder()
        if let title = score.title, !title.isEmpty { conductor.meta(0x03, Array(title.utf8), at: 0) }
        var written: (beats: Int, beatType: Int)?
        for (i, m) in score.measures.enumerated() {
            guard let signature = signature(for: m), i == 0 || written.map({ $0 != signature }) ?? true else { continue }
            let power = signature.beatType.trailingZeroBitCount
            conductor.meta(0x58, [UInt8(signature.beats), UInt8(power), 24, 8], at: tick(m.startBeat))
            written = signature
        }
        if score.measures.isEmpty { conductor.meta(0x58, [4, 2, 24, 8], at: 0) }
        let fifths = Int8(max(-7, min(7, score.keyFifths)))
        conductor.meta(0x59, [UInt8(bitPattern: fifths), isMinor ? 1 : 0], at: 0)
        if let bpm = score.initialTempoBPM, bpm > 0, bpm.isFinite {
            let micros = max(1, min(0xFF_FFFF, Int((60_000_000 / bpm).rounded())))
            conductor.meta(0x51, [UInt8(micros >> 16), UInt8(micros >> 8 & 0xFF), UInt8(micros & 0xFF)], at: 0)
        }

        var tracks = [conductor.bytes(endingAt: endTick)]
        for (channel, hand) in [Hand.right, .left].enumerated() {
            var track = TrackBuilder()
            track.meta(0x03, Array(hand.displayName.utf8), at: 0)
            track.channel([0xC0 | UInt8(channel), 0], at: 0)
            for n in notes where n.hand == hand {
                track.noteOn([0x90 | UInt8(channel), UInt8(n.midi), UInt8(n.velocity)], at: n.on)
                track.noteOff([0x80 | UInt8(channel), UInt8(n.midi), 64], at: n.off)
            }
            tracks.append(track.bytes(endingAt: endTick))
        }

        var bytes = Array("MThd".utf8) + be32(6) + be16(1) + be16(tracks.count) + be16(ticksPerQuarter)
        for body in tracks { bytes += Array("MTrk".utf8) + be32(body.count) + body }
        return Data(bytes)
    }

    /// The time signature to write at the start of a measure. A measure shorter or longer than its
    /// signature (a pickup) gets a signature of its actual length, so reading the file back keeps it.
    static func signature(for measure: ScoreMeasure) -> (beats: Int, beatType: Int)? {
        let ts = measure.timeSignature
        let nominalIsValid = ts.beats > 0 && ts.beats < 256 && ts.beatType > 0 && ts.beatType.nonzeroBitCount == 1
        if abs(measure.lengthBeats - ts.quarterBeatsPerMeasure) < 1e-6 {
            return nominalIsValid ? (ts.beats, ts.beatType) : nil
        }
        for beatType in [4, 8, 16, 32] {
            let beats = measure.lengthBeats * Double(beatType) / 4
            if abs(beats - beats.rounded()) < 1e-6, beats >= 1, beats < 256 { return (Int(beats.rounded()), beatType) }
        }
        return nominalIsValid ? (ts.beats, ts.beatType) : nil
    }

    /// Collects timed events and serialises them with delta times. At equal ticks, meta events come
    /// first, then program changes, note-offs and note-ons, so a re-struck key is released before it
    /// sounds again.
    struct TrackBuilder {
        private var events: [(tick: Int, order: Int, sequence: Int, bytes: [UInt8])] = []

        mutating func meta(_ type: UInt8, _ payload: [UInt8], at tick: Int) {
            add([0xFF, type] + MIDIFileWriter.variableLength(payload.count) + payload, at: tick, order: 0)
        }

        mutating func channel(_ bytes: [UInt8], at tick: Int) { add(bytes, at: tick, order: 1) }
        mutating func noteOff(_ bytes: [UInt8], at tick: Int) { add(bytes, at: tick, order: 2) }
        mutating func noteOn(_ bytes: [UInt8], at tick: Int) { add(bytes, at: tick, order: 3) }

        private mutating func add(_ bytes: [UInt8], at tick: Int, order: Int) {
            events.append((tick, order, events.count, bytes))
        }

        func bytes(endingAt endTick: Int) -> [UInt8] {
            let sorted = events.sorted { ($0.tick, $0.order, $0.sequence) < ($1.tick, $1.order, $1.sequence) }
            var out: [UInt8] = []
            var now = 0
            for e in sorted {
                out += MIDIFileWriter.variableLength(e.tick - now) + e.bytes
                now = e.tick
            }
            return out + MIDIFileWriter.variableLength(max(0, endTick - now)) + [0xFF, 0x2F, 0x00]
        }
    }

    /// MIDI variable-length quantity: 7 bits per byte, most significant first, high bit set on all but the last.
    static func variableLength(_ value: Int) -> [UInt8] {
        var v = max(0, min(value, 0x0FFF_FFFF))
        var out = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            out.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return out
    }

    private static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private static func be32(_ v: Int) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
}

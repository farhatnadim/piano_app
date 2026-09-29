import Foundation

/// Errors thrown by `MIDIFileParser`.
public enum MIDIFileError: Error, Equatable {
    /// The data does not start with an `MThd` header (or a RIFF `RMID` wrapper around one).
    case notAMIDIFile
    /// Format 2 (independent sequences) or an unknown format.
    case unsupportedFormat(Int)
    /// The header uses SMPTE time division instead of ticks per quarter note.
    case smpteTimeDivisionNotSupported
    /// The data ended in the middle of a structure.
    case truncated
    /// A structural error (bad variable-length quantity, data byte without running status, …).
    case invalidData(String)
    /// No pitched notes (outside the drum channel) were found.
    case noNotes
}

/// Reads a Standard MIDI File (format 0 or 1, PPQ timing) into a `Score`.
///
/// Note-ons from every track (except channel 10, drums) are collected; attacks within 1/24 of a quarter
/// note of a group's first note become one event at that first note's tick. Measures are derived from
/// the time-signature meta events (default 4/4) and cover everything up to the end of the last note.
/// The first tempo event gives `initialTempoBPM`, the first key signature `keyFifths`; the first track's
/// name becomes the title. Note-on velocities are kept as `ScoreNote.velocity` (0...1).
///
/// Hands come from track names that say so ("Right hand", "LH", "Treble", ...), then from the usual
/// layout of two note tracks (right hand first), and otherwise from a split at middle C.
public enum MIDIFileParser {
    public static func parse(data: Data) throws -> Score {
        let bytes = [UInt8](data)
        var p = try headerStart(bytes)

        guard p + 8 <= bytes.count, tag(bytes, p) == "MThd" else { throw MIDIFileError.notAMIDIFile }
        let headerLength = Int(u32(bytes, p + 4))
        guard headerLength >= 6, p + 8 + 6 <= bytes.count else { throw MIDIFileError.truncated }
        let format = u16(bytes, p + 8)
        let division = u16(bytes, p + 12)
        guard format <= 1 else { throw MIDIFileError.unsupportedFormat(format) }
        guard division & 0x8000 == 0 else { throw MIDIFileError.smpteTimeDivisionNotSupported }
        guard division > 0 else { throw MIDIFileError.invalidData("zero ticks per quarter note") }
        let ppq = division
        p += 8 + headerLength

        // Read every MTrk chunk present (the header's track count is often wrong in the wild).
        var tracks: [TrackContents] = []
        while p + 8 <= bytes.count {
            let chunkType = tag(bytes, p)
            let length = Int(u32(bytes, p + 4))
            let start = p + 8
            let end = min(start + length, bytes.count)  // tolerate a chunk length running past the end
            if chunkType == "MTrk" {
                tracks.append(try parseTrack(bytes, start..<end))
            } else if !chunkType.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
                break  // trailing garbage
            }
            p = end
        }

        var notes: [(tick: Int, midi: Int, duration: Int, velocity: Int, track: Int)] = []
        var tempos: [(tick: Int, microseconds: Int)] = []
        var signatures: [(tick: Int, signature: TimeSignature)] = []
        var keys: [(tick: Int, fifths: Int)] = []
        var noteTrackNames: [String?] = []
        for t in tracks {
            if !t.notes.isEmpty {
                let track = noteTrackNames.count
                notes.append(contentsOf: t.notes.map { ($0.tick, $0.midi, $0.duration, $0.velocity, track) })
                noteTrackNames.append(t.name)
            }
            tempos.append(contentsOf: t.tempos)
            signatures.append(contentsOf: t.timeSignatures)
            keys.append(contentsOf: t.keySignatures)
        }
        guard !notes.isEmpty else { throw MIDIFileError.noNotes }

        // Stable sorts keep track order for simultaneous events.
        notes = notes.enumerated().sorted {
            ($0.element.tick, $0.element.midi, $0.offset) < ($1.element.tick, $1.element.midi, $1.offset)
        }.map(\.element)
        tempos = tempos.enumerated().sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }.map(\.element)
        keys = keys.enumerated().sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }.map(\.element)
        signatures = signatures.enumerated().sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }.map(\.element)

        let lastOnset = notes.map(\.tick).max() ?? 0
        let endTick = notes.map { $0.tick + $0.duration }.max() ?? 0
        let measures = buildMeasures(signatures: signatures, ppq: ppq, lastOnset: lastOnset, endTick: endTick)

        // Group attacks.
        let window = Double(ppq) / 24
        var events: [ScoreEvent] = []
        var lastDuration = 0.0
        var measureCursor = 0
        var i = 0
        while i < notes.count {
            let first = notes[i].tick
            var pitches = Set<Int>()
            var longest = 0
            var j = i
            while j < notes.count, Double(notes[j].tick - first) <= window {
                pitches.insert(notes[j].midi)
                longest = max(longest, notes[j].duration)
                j += 1
            }
            let beat = Double(first) / Double(ppq)
            while measureCursor + 1 < measures.count, measures[measureCursor + 1].startBeat <= beat + 1e-9 {
                measureCursor += 1
            }
            let m = measures[measureCursor]
            events.append(ScoreEvent(index: events.count, beat: beat, measureIndex: m.index, sourceMeasureIndex: m.sourceIndex,
                                     beatInMeasure: beat - m.startBeat, pitches: pitches.sorted(), durationBeats: 0))
            lastDuration = Double(longest) / Double(ppq)
            i = j
        }
        for k in events.indices {
            events[k].durationBeats = k + 1 < events.count ? events[k + 1].beat - events[k].beat : lastDuration
        }

        // A single-track file's name is the song title, so only multi-track files name their hands.
        let trackHands = handsForNoteTracks(names: tracks.count > 1 ? noteTrackNames : noteTrackNames.map { _ in nil })
        var cursor = 0
        let scoreNotes = notes.map { n -> ScoreNote in
            let beat = Double(n.tick) / Double(ppq)
            while cursor + 1 < measures.count, measures[cursor + 1].startBeat <= beat + 1e-9 { cursor += 1 }
            let hand = trackHands[n.track] ?? (n.midi >= 60 ? .right : .left)
            return ScoreNote(midi: n.midi, beat: beat, durationBeats: Double(n.duration) / Double(ppq),
                             hand: hand, measureIndex: measures[cursor].index, velocity: Double(n.velocity) / 127)
        }

        let tempo = tempos.first.flatMap { $0.microseconds > 0 ? 60_000_000 / Double($0.microseconds) : nil }
        return Score(title: tracks.first?.name, composer: nil, measures: measures, events: events, initialTempoBPM: tempo,
                     notes: scoreNotes, keyFifths: keys.first?.fifths ?? 0)
    }

    // MARK: - Hands

    /// The hand each note track plays, or nil where only the middle-C split can tell.
    ///
    /// Named tracks win; with exactly two note tracks the unnamed one takes the other hand, and two unnamed
    /// tracks follow the common layout of right hand first.
    static func handsForNoteTracks(names: [String?]) -> [Hand?] {
        var hands = names.map { $0.flatMap(hand(forTrackName:)) }
        if hands.count == 2 {
            switch (hands[0], hands[1]) {
            case (nil, nil): hands = [.right, .left]
            case (let first?, nil): hands[1] = first == .right ? .left : .right
            case (nil, let second?): hands[0] = second == .right ? .left : .right
            default: break
            }
        }
        return hands
    }

    /// The hand a track name refers to ("Piano RH", "Left Hand", "Treble", "Bass"), or nil if it names
    /// neither or both. "RH"/"LH" must be whole words so names like "Rhythm" don't count.
    static func hand(forTrackName name: String) -> Hand? {
        let lower = name.lowercased()
        let words = Set(lower.replacingOccurrences(of: ".", with: "")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let right = lower.contains("right") || lower.contains("treble") || words.contains("rh")
        let left = lower.contains("left") || lower.contains("bass") || words.contains("lh")
        if right == left { return nil }
        return right ? .right : .left
    }

    // MARK: - Measures

    /// Lays out measures from time-signature changes. A change that falls inside a measure ends that
    /// measure early so the new signature starts a fresh measure at the change.
    static func buildMeasures(signatures: [(tick: Int, signature: TimeSignature)], ppq: Int,
                              lastOnset: Int, endTick: Int) -> [ScoreMeasure] {
        var measures: [ScoreMeasure] = []
        var signature = TimeSignature.common
        var next = 0
        var start = 0.0  // ticks
        let q = Double(ppq)
        repeat {
            while next < signatures.count, Double(signatures[next].tick) <= start + 1e-9 {
                signature = signatures[next].signature
                next += 1
            }
            var length = signature.quarterBeatsPerMeasure * q
            if next < signatures.count, Double(signatures[next].tick) < start + length - 1e-9 {
                length = Double(signatures[next].tick) - start
            }
            measures.append(ScoreMeasure(index: measures.count, sourceIndex: measures.count, number: String(measures.count + 1),
                                         startBeat: start / q, lengthBeats: length / q, timeSignature: signature))
            start += length
        } while start <= Double(lastOnset) + 1e-9 || start < Double(endTick) - 1e-9
        return measures
    }

    // MARK: - Tracks

    struct TrackContents {
        var notes: [(tick: Int, midi: Int, duration: Int, velocity: Int)] = []
        var tempos: [(tick: Int, microseconds: Int)] = []
        var timeSignatures: [(tick: Int, signature: TimeSignature)] = []
        var keySignatures: [(tick: Int, fifths: Int)] = []
        var name: String?
    }

    static func parseTrack(_ bytes: [UInt8], _ range: Range<Int>) throws -> TrackContents {
        var track = TrackContents()
        var p = range.lowerBound
        let end = range.upperBound
        var tick = 0
        var runningStatus: UInt8?
        // Open notes per (channel, key), oldest first, as indices into `track.notes`.
        var open: [Int: [Int]] = [:]

        func byte() throws -> UInt8 {
            guard p < end else { throw MIDIFileError.truncated }
            defer { p += 1 }
            return bytes[p]
        }
        func variableLength() throws -> Int {
            var value = 0
            for _ in 0..<4 {
                let b = try byte()
                value = (value << 7) | Int(b & 0x7F)
                if b & 0x80 == 0 { return value }
            }
            throw MIDIFileError.invalidData("variable-length quantity longer than 4 bytes")
        }
        func payload(_ length: Int) throws -> ArraySlice<UInt8> {
            guard length >= 0, p + length <= end else { throw MIDIFileError.truncated }
            defer { p += length }
            return bytes[p..<(p + length)]
        }
        func close(_ key: Int, at t: Int) {
            guard var list = open[key], !list.isEmpty else { return }
            let idx = list.removeFirst()
            track.notes[idx].duration = t - track.notes[idx].tick
            open[key] = list
        }

        parsing: while p < end {
            tick += try variableLength()
            var status = try byte()
            switch status {
            case 0xFF:
                let type = try byte()
                let data = try payload(try variableLength())
                switch type {
                case 0x2F:
                    break parsing
                case 0x51 where data.count >= 3:
                    let d = Array(data)
                    track.tempos.append((tick, Int(d[0]) << 16 | Int(d[1]) << 8 | Int(d[2])))
                case 0x58 where data.count >= 2:
                    let d = Array(data)
                    if d[0] > 0, d[1] < 16 {
                        track.timeSignatures.append((tick, TimeSignature(beats: Int(d[0]), beatType: 1 << Int(d[1]))))
                    }
                case 0x59 where data.count >= 2:
                    let fifths = Int(Int8(bitPattern: data[data.startIndex]))
                    if (-7...7).contains(fifths) { track.keySignatures.append((tick, fifths)) }
                case 0x03 where track.name == nil:
                    let text = (String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                    if !text.isEmpty { track.name = text }
                default:
                    break
                }
            case 0xF0, 0xF7:
                _ = try payload(try variableLength())
            case 0xF1, 0xF3:
                _ = try payload(1)
            case 0xF2:
                _ = try payload(2)
            case 0xF4...0xFE:
                break
            default:
                var first: UInt8
                if status < 0x80 {
                    guard let running = runningStatus else {
                        throw MIDIFileError.invalidData("data byte without running status")
                    }
                    first = status
                    status = running
                } else {
                    runningStatus = status
                    first = try byte()
                }
                let kind = status & 0xF0
                let channel = Int(status & 0x0F)
                let second: UInt8 = (kind == 0xC0 || kind == 0xD0) ? 0 : try byte()
                guard channel != 9 else { continue }
                let key = channel << 7 | Int(first & 0x7F)
                if kind == 0x90, second > 0 {
                    open[key, default: []].append(track.notes.count)
                    track.notes.append((tick, Int(first & 0x7F), 0, Int(second & 0x7F)))
                } else if kind == 0x80 || kind == 0x90 {
                    close(key, at: tick)
                }
            }
        }
        // Notes never switched off last until the end of the track.
        for key in open.keys.sorted() {
            while let list = open[key], !list.isEmpty { close(key, at: tick) }
        }
        return track
    }

    // MARK: - Bytes

    /// Offset of the `MThd` header, looking inside a RIFF `RMID` wrapper if present.
    private static func headerStart(_ bytes: [UInt8]) throws -> Int {
        guard bytes.count >= 12, tag(bytes, 0) == "RIFF", tag(bytes, 8) == "RMID" else { return 0 }
        var p = 12
        while p + 8 <= bytes.count {
            let size = Int(bytes[p + 4]) | Int(bytes[p + 5]) << 8 | Int(bytes[p + 6]) << 16 | Int(bytes[p + 7]) << 24
            if tag(bytes, p) == "data" { return p + 8 }
            p += 8 + size + (size & 1)
        }
        throw MIDIFileError.notAMIDIFile
    }

    private static func tag(_ b: [UInt8], _ p: Int) -> String {
        guard p + 4 <= b.count else { return "" }
        return String(decoding: b[p..<(p + 4)], as: UTF8.self)
    }

    private static func u16(_ b: [UInt8], _ p: Int) -> Int {
        Int(b[p]) << 8 | Int(b[p + 1])
    }

    private static func u32(_ b: [UInt8], _ p: Int) -> UInt32 {
        UInt32(b[p]) << 24 | UInt32(b[p + 1]) << 16 | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3])
    }
}

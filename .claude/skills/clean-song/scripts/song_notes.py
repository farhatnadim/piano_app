"""Reads a clean song's Swift file (PianoCoach/Game/<Song>.swift): its notes in video seconds."""
import re
NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
def nm(m): return f'{NAMES[m % 12]}{m // 12 - 1}'

def load(path, beat_zero=None):
    """(notes as (video seconds, seconds long, MIDI, bar), beat zero, tempo, sixteenths per bar)."""
    src = re.sub(r'//[^\n]*', '', open(path).read())
    body = src[src.index('bars'):]
    tempo = float(re.search(r'tempoBPM: ([\d.]+)', src).group(1))
    vt0 = beat_zero if beat_zero is not None else float(re.search(r'videoTimeOfBeatZero: ([\d.]+)', src).group(1))
    sig = re.search(r'TimeSignature\(beats: (\d+), beatType: (\d+)\)', src)
    per_bar = int(int(sig.group(1)) * 16 / int(sig.group(2))) if sig else 16
    pickup = re.search(r'pickupSixteenths: (\d+)', src)
    six = 60 / tempo / 4
    notes, start = [], 0
    for b, (r, l) in enumerate(re.findall(r'\(\[(.*?)\],\s*\[(.*?)\]\)', body, re.S)):
        for part in (r, l):
            for at, length, m in re.findall(r'\(([\d.]+), ([\d.]+), (\d+)\)', part):
                notes.append((vt0 + (start + float(at)) * six, float(length) * six, int(m), b))
        start += int(pickup.group(1)) if (b == 0 and pickup) else per_bar
    return sorted(notes), vt0, tempo, per_bar

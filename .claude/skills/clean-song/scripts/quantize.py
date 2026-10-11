"""Sets the lit keys on a sixteenth-note grid and lays them out in bars, for the song's Swift file.

python3 quantize.py <work dir> --start <s> --end <s>
    Only the song: --start/--end are recording seconds around it (leave out the title card and end
    screen). Without --sixteenth, prints the likely grid periods and stops.
python3 quantize.py <work dir> --start <s> --end <s> --sixteenth <s> [--bar 16] [--pickup 0] [--split 55]
                    [--left-color r,g,b --right-color r,g,b]
    --bar: sixteenths per bar (4/4: 16, 3/4: 12, 6/8: 12, 3/8: 6). --pickup: sixteenths from the first bar
    line back to the first note (0 when the song starts on a bar line). Hands: notes below --split (MIDI)
    are the left hand, unless the tutorial colours the hands, then give each hand's colour (runs.json).
Writes bars.swift (paste into the song) and quant.json; prints every bar, and notes that sit off the grid
(triplets, swing, or a misread) for a closer look."""
import argparse, json, numpy as np
ap = argparse.ArgumentParser()
ap.add_argument('dir'); ap.add_argument('--start', type=float, required=True); ap.add_argument('--end', type=float, required=True)
ap.add_argument('--sixteenth', type=float); ap.add_argument('--bar', type=int, default=16)
ap.add_argument('--pickup', type=int, default=0); ap.add_argument('--split', type=int, default=55)
ap.add_argument('--left-color'); ap.add_argument('--right-color')
a = ap.parse_args()
names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
def nm(m): return f'{names[m % 12]}{m // 12 - 1}'
runs = [r for r in json.load(open(f'{a.dir}/runs.json')) if a.start <= r[0] <= a.end]
onsets = np.array(sorted({round(r[0], 3) for r in runs}))
if a.sixteenth is None:
    scores = sorted(((abs(np.exp(2j * np.pi * onsets / p).mean()), p) for p in np.arange(0.08, 0.6, 0.0005)), reverse=True)
    peaks = []
    for r, p in scores:
        if all(abs(p - q) > 0.01 for _, q in peaks): peaks.append((r, p))
        if len(peaks) == 8: break
    print('grid periods (seconds) by how well the onsets sit on them — the sixteenth is usually the best one or')
    print('half of it; the shortest notes last about one sixteenth:')
    for r, p in peaks: print(f'  {p:.4f} s  fit {r:.2f}   ({60 / p / 4:.1f} quarter notes a minute if a sixteenth)')
    lengths = np.array([r[1] for r in runs]); print(f'shortest notes last about {np.percentile(lengths, 10):.3f} s')
    raise SystemExit
p = a.sixteenth; t0 = onsets[0]
for _ in range(6):
    k = np.round((onsets - t0) / p)
    p, t0 = np.polyfit(k, onsets, 1)
res = onsets - (t0 + k * p)
print(f'sixteenth {p:.5f} s = {60 / p / 4:.2f} quarter notes a minute; timing off the grid: rms {res.std() * 1000:.0f} ms, '
      f'max {abs(res).max() * 1000:.0f} ms')
def colour_hand(col):
    if not (a.left_color and a.right_color): return None
    l = np.array([int(v) for v in a.left_color.split(',')]); r = np.array([int(v) for v in a.right_color.split(',')])
    return 'left' if np.linalg.norm(np.array(col) - l) < np.linalg.norm(np.array(col) - r) else 'right'
k_first = int(np.round((runs[0][0] - t0) / p))
notes, odd = [], []
for t, d, m, col in runs:
    exact = (t - t0) / p - k_first + a.pickup
    k = int(round(exact)); L = max(1, int(round((d + 0.02) / p)))
    hand = colour_hand(col) or ('left' if m < a.split else 'right')
    notes.append((k, L, m, hand))
    if abs(exact - k) > 0.3: odd.append(f'bar {k // a.bar} sixteenth {exact % a.bar:.2f} {nm(m)}')
notes.sort()
bars = {}
for k, L, m, hand in notes:
    bars.setdefault(k // a.bar, {'right': [], 'left': []})[hand].append((k % a.bar, L, m))
lines = []
for b in range(max(bars) + 1):
    bar = bars.get(b, {'right': [], 'left': []})
    print(f'{b:3d} R ' + ' '.join(f'{nm(m)}@{at}x{L}' for at, L, m in bar['right']))
    print(f'    L ' + ' '.join(f'{nm(m)}@{at}x{L}' for at, L, m in bar['left']))
    fmt = lambda xs: '[' + ', '.join(f'({at}, {L}, {m})' for at, L, m in xs) + ']'
    lines.append(f'            ({fmt(bar["right"])},\n             {fmt(bar["left"])}),')
open(f'{a.dir}/bars.swift', 'w').write('\n'.join(lines) + '\n')
rec_beat0 = t0 + (k_first - a.pickup) * p
json.dump({'sixteenth': p, 'tempoBPM': 60 / p / 4, 'recordingTimeOfBeatZero': rec_beat0, 'bar': a.bar},
          open(f'{a.dir}/quant.json', 'w'))
print(f'beat 0 at {rec_beat0:.3f} s of the recording; bars.swift written')
print('off the grid (more than a third of a sixteenth):', odd or 'none')

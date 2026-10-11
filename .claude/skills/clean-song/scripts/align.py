"""Finds where beat 0 falls in the video, from paused frames (pause.sh): at each, the keys lit in the
video must be exactly the notes sounding then.
python3 align.py <work dir> <Song.swift> [--from 0 --to 60]
Prints, for every beat-0 time that fits all frames, and per frame what the video lights against the notes.
Several ranges fitting means the music repeats: pause at more (different) moments."""
import argparse, glob, json, os, numpy as np
from PIL import Image
from song_notes import load, nm
ap = argparse.ArgumentParser(); ap.add_argument('dir'); ap.add_argument('song')
ap.add_argument('--from', dest='lo', type=float, default=0); ap.add_argument('--to', dest='hi', type=float, default=60)
a = ap.parse_args()
km = json.load(open(f'{a.dir}/keymap.json'))
shots = []
for png in sorted(glob.glob(f'{a.dir}/paused/*.png')):
    log = png[:-4] + '.log'
    lines = [l for l in open(log) if 'PianoCoach: wall' in l]
    if not lines: continue
    vt = float(lines[-1].split()[4])
    im = np.array(Image.open(png).convert('RGB')).astype(int)
    lit = set()
    for k in km['keys']:
        c = int(round(k['x'])); px = im[k['y'], c - 4:c + 5].mean(axis=0)
        if px.max() - px.min() > 45: lit.add(k['midi'])      # the pause screen dims the video a little
    shots.append((vt, lit))
print(len(shots), 'paused frames at', [round(v, 2) for v, _ in shots])
notes, _, _, _ = load(a.song, 0)
fits = []
for z in np.arange(a.lo, a.hi, 0.01):
    ok = sum(lit == {m for t, d, m, b in notes if z + t <= vt < z + t + d} for vt, lit in shots)
    fits.append((round(z, 2), ok))
best = max(ok for _, ok in fits)
ranges, cur = [], []
for z, ok in fits:
    if ok == best: cur.append(z)
    elif cur: ranges.append(cur); cur = []
if cur: ranges.append(cur)
print(f'beat 0 fitting {best} of {len(shots)} frames:', ', '.join(f'{r[0]:.2f}-{r[-1]:.2f} s' for r in ranges))
mid = ranges[0][len(ranges[0]) // 2]
print(f'at {mid:.2f} s:')
for vt, lit in shots:
    want = {m for t, d, m, b in notes if mid + t <= vt < mid + t + d}
    print(f'  video {vt:7.3f}: lights {sorted(map(nm, lit))}, notes {sorted(map(nm, want))}', 'ok' if lit == want else 'DIFFERENT')

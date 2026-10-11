"""Finds the tutorial's on-screen piano in the recording and names its keys.

Step 1 — look:   python3 keyboard.py <work dir> --frame <recording seconds>
    Saves frame.png and labels.png (the bottom of the white keys, where tutorials print "C4"), and
    prints the white-key band, the black-key band, the white-key edges and the black keys' centres.
Step 2 — name:   python3 keyboard.py <work dir> --frame <s> --c-left <x> --c-midi <midi>
    <x> is the left edge (in screen pixels) of a white key you can name — a labelled C — and <midi> its
    note (C4 = 60). Writes keymap.json: every key's MIDI, centre and which band to read it in.
Pick a frame with few keys lit, inside the song (not the title card)."""
import argparse, json, subprocess, numpy as np
from PIL import Image

ap = argparse.ArgumentParser()
ap.add_argument('dir'); ap.add_argument('--frame', type=float, required=True)
ap.add_argument('--c-left', type=float); ap.add_argument('--c-midi', type=int)
a = ap.parse_args()
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', str(a.frame), '-i', f'{a.dir}/screen.mp4', '-frames:v', '1',
                f'{a.dir}/frame.png'], check=True)
im = np.array(Image.open(f'{a.dir}/frame.png').convert('RGB')).astype(int)
H, W, _ = im.shape
bright = im.min(axis=2) > 170          # white (or cream) keys
dark = im.max(axis=2) < 80             # black keys and background

# The keyboard: rows that are mostly bright (white keys below the black ones), and above them rows that
# alternate bright and dark (where the black keys are).
rows = [(y, bright[y].mean(), dark[y].mean()) for y in range(H)]
def band(ys):
    best, cur = [], []
    for y in ys:
        cur = cur + [y] if cur and y == cur[-1] + 1 else [y]
        if len(cur) > len(best): best = cur
    return best
bb = band([y for y, b, d in rows if 0.25 < b < 0.75 and d > 0.25])
wb = []
for y in range(bb[-1] + 1, min(H, bb[-1] + 40)):
    if rows[y][1] > 0.7: wb.append(y)
    elif wb: break
for y in range(wb[-1] + 1, H):
    if rows[y][1] > 0.7 and rows[y][2] < 0.05: wb.append(y)
    else: break
# Low on the keys: YouTube's pause controls (progress bar, buttons) cover the top of the keyboard.
white_y = wb[0] + (wb[-1] - wb[0]) * 85 // 100; black_y = bb[0] + (bb[-1] - bb[0]) * 80 // 100
# The keyboard spans the columns where the black-key band has its dark keys.
dark_cols = np.where(dark[black_y])[0]; x0, x1 = int(dark_cols.min()), int(dark_cols.max())
print(f'frame {W}x{H}; white keys read at y={white_y} (band {wb[0]}-{wb[-1]}), black keys at y={black_y} '
      f'(band {bb[0]}-{bb[-1]}), keyboard x {x0}-{x1}')

# White-key edges: the thin dark lines between white keys.
row = im[white_y, x0:x1 + 1].mean(axis=1)
edges, i = [], 0
while i < len(row):
    if row[i] < 170:
        j = i
        while j < len(row) and row[j] < 170: j += 1
        if j - i < 12: edges.append(x0 + (i + j - 1) / 2)
        i = j
    else: i += 1
width = float(np.median(np.diff(edges)))
# Refined over the whole keyboard (a label or a lit key can hide an edge, or add one).
n = np.round((np.array(edges) - edges[0]) / width)
fit = np.abs(np.array(edges) - edges[0] - n * width) < width * 0.15
width = float(np.polyfit(n[fit], np.array(edges)[fit], 1)[0])
print(f'white key width {width:.2f}px; edges: {[round(e) for e in edges]}')
row = im[black_y, x0:x1 + 1].max(axis=1)
blacks, i = [], 0
while i < len(row):
    if row[i] < 80:
        j = i
        while j < len(row) and row[j] < 80: j += 1
        if width * 0.35 < j - i < width * 0.9: blacks.append(x0 + (i + j - 1) / 2)
        i = j
    else: i += 1
print(f'black keys ({len(blacks)}): {[round(b) for b in blacks]}')
top = wb[0] + (wb[-1] - wb[0]) // 2
Image.fromarray(im[top:wb[-1] + 1, x0:x1 + 1].astype(np.uint8)).resize(((x1 - x0 + 1), (wb[-1] - top + 1) * 2)).save(f'{a.dir}/labels.png')
print(f'labels.png: the bottom of the white keys, x offset {x0} (look for a "C" label)')

if a.c_left is not None:
    steps = [0, 2, 4, 5, 7, 9, 11]
    keys = []
    for k in range(-60, 60):
        left = a.c_left + width * k
        centre = left + width / 2
        if centre < x0 + width * 0.3 or centre > x1 - width * 0.3: continue
        keys.append({'midi': a.c_midi + 12 * (k // 7) + steps[k % 7], 'x': centre, 'y': white_y, 'kind': 'white'})
    # Black keys sit near the edge after C, D, F, G and A, each a little off it in its own way; the offsets
    # come from the black keys seen (a lit one may be missed), and every black key is placed from them.
    offsets = {}
    for b in blacks:
        k = round((b - a.c_left) / width) - 1        # the white key left of the nearest edge
        offsets.setdefault(k % 7, []).append(b - (a.c_left + width * (k + 1)))
    for k in range(-60, 60):
        if k % 7 in (2, 6): continue                 # no black key after E or B
        x = a.c_left + width * (k + 1) + float(np.median(offsets.get(k % 7, [0])))
        if x < x0 + width * 0.2 or x > x1 - width * 0.2: continue
        keys.append({'midi': a.c_midi + 12 * (k // 7) + steps[k % 7] + 1, 'x': x, 'y': black_y, 'kind': 'black'})
    keys.sort(key=lambda k: k['midi'])
    midis = [k['midi'] for k in keys]
    assert len(set(midis)) == len(midis), 'two keys got the same note: check --c-left'
    names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
    json.dump({'width': width, 'keys': keys}, open(f'{a.dir}/keymap.json', 'w'))
    print('keymap.json:', ' '.join(f"{names[k['midi'] % 12]}{k['midi'] // 12 - 1}:{k['x']:.0f}" for k in keys))

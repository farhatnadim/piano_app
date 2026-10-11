"""Reads which keys light up in every frame of the recording.
python3 read_keys.py <work dir>      (needs screen.mp4, frame_times.txt, keymap.json)
Writes runs.json: one entry per time a key lit up — [recording seconds, seconds lit, MIDI, [r, g, b]] —
and prints them. A lit key is coloured (tutorials light keys in a hand's colour); unlit keys are white,
cream or black. The colour tells the hands apart when the tutorial uses one per hand."""
import json, subprocess, sys, os, numpy as np
d = sys.argv[1]
km = json.load(open(f'{d}/keymap.json'))
times = np.array([float(l.strip().strip(',')) for l in open(f'{d}/frame_times.txt') if l.strip()])
N = len(times)
xs = [k['x'] for k in km['keys']]
x0 = int(min(xs) - km['width']); x1 = int(max(xs) + km['width']); w = (x1 - x0) // 2 * 2
strips = {}
for y in sorted({k['y'] for k in km['keys']}):
    path = f'{d}/strip_{y}.raw'
    if not os.path.exists(path):
        subprocess.run(['ffmpeg', '-v', 'quiet', '-y', '-i', f'{d}/screen.mp4', '-fps_mode', 'passthrough', '-vf',
                        f'crop={w}:2:{x0}:{y // 2 * 2},format=rgb24', '-f', 'rawvideo', '-pix_fmt', 'rgb24', path],
                       check=True)
    a = np.fromfile(path, dtype=np.uint8)
    assert a.size == N * 2 * w * 3, f'{path}: {a.size // (2 * w * 3)} frames, frame_times.txt has {N}'
    strips[y] = a.reshape(N, 2, w, 3)[:, 0].astype(int)
names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
runs = []
for k in km['keys']:
    c = int(round(k['x'])) - x0; h = max(2, int(km['width'] * (0.17 if k['kind'] == 'white' else 0.11)))
    px = strips[k['y']][:, c - h:c + h + 1].mean(axis=1)
    lit = px.max(axis=1) - px.min(axis=1) > 60
    i = 0
    while i < N:
        if lit[i]:
            j = i
            while j < N and lit[j]: j += 1
            runs.append([float(times[i]), float(times[min(j, N - 1)] - times[i]), k['midi'],
                         [int(v) for v in px[i:j].mean(axis=0)]])
            i = j
        else: i += 1
runs.sort()
json.dump(runs, open(f'{d}/runs.json', 'w'))
for t, l, m, col in runs:
    print(f'{t:8.3f} {l:6.3f} {names[m % 12]}{m // 12 - 1:<3} rgb{tuple(col)}')
print(len(runs), 'runs')

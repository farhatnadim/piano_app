"""The last check: every note of a clean song's Swift file against the keys the video lit, in one or more
recordings (record.sh, read_keys.py, quantize.py each). Use two recordings: the simulator's screen
recording drops frames now and then, and a note both agree on is the video's own.
python3 check_song.py <Song.swift> <work dir> [<work dir> ...]
Clean means: every note matched, nothing in the video missing from the notes, timing within ~0.1 s."""
import json, sys, numpy as np
from song_notes import load, nm
notes, vt0, tempo, _ = load(sys.argv[1])
print(f'{len(notes)} notes, {notes[-1][3] + 1} bars, beat 0 at {vt0} s of the video, {tempo} quarter notes a minute')
first, last = notes[0][0], max(t + d for t, d, m, b in notes)
for d in sys.argv[2:]:
    q = json.load(open(f'{d}/quant.json'))
    offset = q['recordingTimeOfBeatZero'] - vt0          # recording seconds minus video seconds
    runs = [(t - offset, l, m) for t, l, m, *_ in json.load(open(f'{d}/runs.json'))]
    runs = [r for r in runs if first - 0.3 < r[0] < last]
    used, errs, missing, late = set(), [], [], []
    for t, l, m, b in notes:
        c = [(abs(rt - t), i) for i, (rt, rl, rm) in enumerate(runs) if rm == m and i not in used and abs(rt - t) < 0.15]
        if not c: missing.append(f'bar {b} {nm(m)} at {t:.2f} s'); continue
        e, i = min(c); used.add(i); errs.append(runs[i][0] - t)
        if e > 0.06: late.append(f'bar {b} {nm(m)} {(runs[i][0] - t) * 1000:+.0f} ms')
    extra = [f'{nm(rm)} at {rt:.2f} s' for i, (rt, rl, rm) in enumerate(runs) if i not in used]
    errs = np.array(errs) if errs else np.zeros(1)
    print(f'{d}: matched {len(notes) - len(missing)}/{len(notes)}, timing mean {errs.mean() * 1000:+.0f} ms, '
          f'worst {abs(errs).max() * 1000:.0f} ms')
    print('  notes the video does not play:', missing or 'none')
    print('  keys the video lights that are not in the notes:', extra or 'none')
    print('  more than 60 ms off:', late or 'none')

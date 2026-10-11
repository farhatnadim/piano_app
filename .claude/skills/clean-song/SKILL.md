---
name: clean-song
description: Make clean notes for a song in Piano Coach from its YouTube piano tutorial — read every note off the video's own falling-notes keyboard, set them on the beat, line them up with the video, check them, and add the song to the app's library. Use when the user adds a song (a YouTube link) and wants it cleaned, "like Für Elise", or asks for clean/exact notes for a song.
---

# Clean notes for a song

Learning a song by listening gives notes with mistakes. A tutorial video that lights keys on an on-screen piano
(Synthesia style) shows the exact notes, so a clean song is read off that keyboard: every key, when it lights,
for how long. Done for "Für Elise (clean notes)" (`PianoCoach/Game/FurElise.swift`) and "Tiki Tiki (clean
notes)" (`PianoCoach/Game/TikiTiki.swift`). Each clean song is one Swift file listed in `CleanSong.all`
(`PianoCoach/Game/CleanSong.swift`); the app adds it to the library once, or puts the clean notes on the song
already there with that video.

Scripts are in `.claude/skills/clean-song/scripts/` (below, `S=` that folder). Work in a scratchpad folder
(`W=`), not the repo. They need the iPad simulator `DD70A857-D383-4992-B7FD-D1008391D095`, ffmpeg, Python 3
with numpy and Pillow. Simulator/Xcode commands need the sandbox off.

## 1. Look at the video

`curl -s "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=<id>&format=json"` gives the title
and channel. The video must show a piano keyboard with lit keys; if it doesn't (sheet music, hands only), say so
and stop — this method can't read it.

Get the chapters too: `curl -sL -A "Mozilla/5.0" "https://www.youtube.com/watch?v=<id>"` and look for
`"chapterRenderer":{"title":{"simpleText":"…"},"timeRangeStartMillis":…` in the page. A **medley** (several
pieces, chapters, long silences between them, often different tempos) becomes one clean song per piece: the
app has one tempo per song. Do every step below per piece (its own work folder with `runs.json` copied in,
`--start`/`--end` around it), name each "<Medley>: <Piece> (clean notes)", one Swift file each in
`PianoCoach/Game/<Medley>/`, listed together in `CleanSong.all` in order (as `CleanSong.doors`). Songs
sharing a video are told apart by title in the library (`sharesVideo`).

## 2. Record it playing

`bash $S/record.sh <video id> $W/rec1` builds the app for the simulator, plays the video from the start, muted,
inside Piano Coach (the DEBUG `-play-video` launch argument) and records the screen until it ends. Check the
printed player states: no `3` (buffering) after it starts playing, or the timing is broken — record again.
(`grep "PianoCoach: wall" play.log | tr -d '\r' | awk '{if ($7!=s) {print $5, $7; s=$7}}'` shows at which video
second it buffered; a recording that buffered only before the first notes, or before a piece of a medley,
is fine for the rest.) A long video takes a while: the script stops after 10 minutes at the most.

Then record a second time (`SKIP_BUILD=1 bash $S/record.sh <id> $W/rec2`): the simulator's screen recording
drops frames now and then, and the final check compares both recordings.

## 3. Find and name the keyboard

`python3 $S/keyboard.py $W/rec1 --frame <seconds into the recording, mid-song>` prints where the keyboard is and
saves `frame.png` and `labels.png`. Look at both (Read tool): find a white key labelled with its note
(tutorials print "C4" etc.), or count from the keyboard's ends. If no key is labelled, the falling notes often
are (letters only): they give the note names; for the octave, the middle C of the keyboard is usually C4 —
check the tune then sits around C4–C6 and the bass around C2–C4. Take the left edge of that C from the printed
white-key edges (`labels.png` starts at the printed x offset), then:

`python3 $S/keyboard.py $W/rec1 --frame <s> --c-left <x> --c-midi <midi, C4 = 60>` → `keymap.json`.
Copy `keymap.json` into `$W/rec2` (same layout).

## 4. Read the lit keys

`python3 $S/read_keys.py $W/rec1` (and rec2) → `runs.json`, one line per key lighting up with its colour. Find
where the song starts and ends (the title card and the end screen light random keys) — those times are
`--start`/`--end` below.

Colours: some tutorials colour each hand (Für Elise: pink right, green left), others colour white and black keys
differently (Tiki Tiki: lime and dark green) — then hands come from the pitch (`--split`). Some colour each
hand with a light shade on white keys and a dark one on black keys (DOORS: green and blue): give the light
shades as `--left-color`/`--right-color`, the dark ones go to the nearest. Which colour is which hand can
change from piece to piece of a medley: per piece, the colour playing higher is the right hand.

## 5. Set the notes on the beat

`python3 $S/quantize.py $W/rec1 --start <s> --end <s>` lists grid periods. The sixteenth is usually the best or
the second-best (half of the best); the shortest notes last about one sixteenth. Then:

`python3 $S/quantize.py $W/rec1 --start <s> --end <s> --sixteenth <s> --bar <16 for 4/4> [--pickup n] [--split 55]`

Read the bars. Signs it's right: repeated sections come out the same bar for bar, chords line up, bars start
with a bass note or a strong beat. If the first bar looks shifted, change `--pickup`. Do the same for rec2.

Look at every note listed as **off the grid**:
- The same note off in both recordings, by about a third of a sixteenth, in a run of them → the music has
  triplets there. Write those notes in thirds of a sixteenth (0.333, 0.667 …), as bar 19 of `TikiTiki.swift`.
- Off by under ~0.09 s in both recordings, alone → the video's own small looseness; the grid is right.
- Off in one recording only → a dropped frame; trust the other.
- Two or three very short notes (under a sixteenth) right before a long one → an ornament (a turn, a grace
  note): write them in halves of a sixteenth (Elevator Jam bars 5–6). Notes of one chord starting a little
  apart, bottom to top → a rolled chord: quarters of a sixteenth (Here I Come's last bar).
- Note lengths that differ by one sixteenth between the recordings are the video's lengths falling between
  two; either is fine (the check looks at where notes start).
- A note that comes out differently from the same bar elsewhere in the song (moved a sixteenth, a length of 1
  instead of 2) and only once → check it against the other recording before deciding it's a variation.

## 6. Write the song

Create `PianoCoach/Game/<Name>.swift` like `TikiTiki.swift`: an `enum Clean<Name>` with `title`
("<Name> (clean notes)") and `static var song: CleanSong` holding the bars from `bars.swift` as one literal
array (the check script reads that array), then `CleanSong(title:videoID:keyName:keyFifths:tempoBPM:
timeSignature:pickupSixteenths:videoTimeOfBeatZero:bars:)`. Work out the key from the notes (`keyFifths`:
flats negative). Leave out the composer unless the video names one. Tempo: from quantize.py. Add the song to
`CleanSong.all`.

Leave `videoTimeOfBeatZero` at 0 for now; step 7 finds it.

## 7. Line the notes up with the video

The recording's clock isn't the video's. Pause the video at known moments and see which keys are down:

`bash $S/pause.sh <id> $W/rec1 <s> <s> …` — 8 to 10 times spread over the song (video seconds; it pauses about
0.8 s after the asked time), then `python3 $S/align.py $W/rec1 <Song.swift> --from 0 --to <a bit past the
first note>`.

It prints the beat-0 times that fit the paused frames. Several separate ranges means the music repeats — pause
at more moments, especially where the song changes. A frame that differs only at a note change (a note just
starting or ending) is the paused frame lagging a little; take the middle of the best range. Put it in
`videoTimeOfBeatZero`. YouTube's pause screen ("More videos", the share button) can cover keys: a key
reported unlit under it is that, if the frame (Read it) shows its falling note reaching the key.

align.py uses every frame in `<dir>/paused`, so for a medley give each piece a folder with only its own
frames (and `keymap.json`). All pieces come from one recording, so recording time minus video time is the
same for all: find it where the fits are narrow, check it fits every piece, and set each piece's
`videoTimeOfBeatZero` to its recording beat 0 (`quant.json`) minus it.

## 8. Check it's clean

`python3 $S/check_song.py PianoCoach/Game/<Name>.swift $W/rec1 $W/rec2`

Clean means: every note matched in both recordings, no keys lit in the video that aren't in the notes, and
timing within about 0.1 s. Anything else, go back to 5.

Then build for the simulator, uninstall and install the app fresh (each clean song is added only once per
install — `addedCleanSong.<video id>` in UserDefaults), and look at it:
`xcrun simctl launch <sim> com.farhatnadim.PianoCoach -screenshot-demo notes start <video id>` (start screen:
key, tempo, note count) and `-screenshot-demo notes <video id>` (the game on the staff). Then build and install
on the iPad (see the iPad build memory). On the iPad the song appears the next time the app opens.

## Tell the user

What was read (bars, notes, key, tempo, where the song starts in the video), anything unusual (triplets,
places the video is loose), the check's result, and that the song shows up as "<Name> (clean notes)" — replacing
the notes of the song with the same video if it was already in the library. Don't commit unless asked.

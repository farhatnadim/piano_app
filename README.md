# Piano Coach

An iPhone, iPad and Mac app that helps a child learn piano from YouTube songs.

## The game

Each song in the library becomes a **falling-notes game**, like Guitar Hero or Synthesia but for a
real piano. Notes fall onto a keyboard. When the child plays the right note, the key lights up
**green**; a wrong note lights **red**.

- **Two views.** *Keys* shows the falling notes and the keyboard labelled with letter names
  (C, D, E…). *Notes* shows a scrolling music staff to learn reading notes; each note lights up as
  it's played. Letter names can be turned off.
- **Two modes.** *Learn*: each note waits at the line until it's played. *Play*: the notes keep
  falling and the child scores points and combos for playing on time.
- **The speed adapts to the child.** If he plays slowly, makes the notes wait or misses, the game
  slows down. When he plays accurately and on time, it speeds up a little.
- **Levels.** Each song remembers its level (its starting speed). A great game (3 stars) moves
  the next game up 10 %; a hard one moves it back down. The library shows each song's difficulty,
  level and best stars.
- **Practise one hand.** Choose right or left hand; the app can play the other hand along with him.
- **Listen first.** The built-in piano plays the song at the current speed while the notes fall.
- **Input.** The device's microphone listens to any piano; a USB/Bluetooth MIDI keyboard gives
  exact notes. The on-screen keyboard can be tapped too (and on a Mac the keys A W S E D F T G Y H
  U J K play C4–C5), which is handy for trying the game without a piano.

### Where the game's notes come from

The app can't read notes directly out of a YouTube video, so it gets them one of two ways:

1. **By listening (automatic).** *Listen to the video to make the game* plays the video once with
   the sound on while the app listens through the microphone and works out the notes. It's easy,
   but approximate: melodies and simple two-hand pieces come out well; dense chords and octaves
   can have mistakes.
2. **From sheet music (exact).** Import a **MIDI** or **MusicXML** file for the song (MuseScore
   and many tutorial channels offer them). Hands, note lengths and bar lines come straight from
   the file.

## Video mode

The *Video* tab plays the YouTube video itself and paces it to the child:

- **Wait for me** – the video pauses when the child stops playing and continues when they start
  again.
- **Follow me** – the video follows the child's position and speed (slower, pause when ahead,
  jump back when they restart). It needs the learned song or synced sheet music.
- **Voice commands** – "slower", "pause", "show the music", "go back", "measure twelve"… (see below).
- **Sheet music** – MusicXML with a moving cursor (tap a measure to jump there), PDF or a photo,
  beside or below the video.

## Build and run

Requirements: a Mac with **Xcode 16 or newer** (Xcode 26 recommended). Targets iOS/iPadOS 17+
and macOS 14+.

1. Open `PianoCoach.xcodeproj`.
2. Select the **PianoCoach** target → *Signing & Capabilities* → choose your **Team** (a free
   Apple ID "Personal Team" works for your own devices). If Xcode complains that the bundle
   identifier is taken, change `com.farhatnadim.PianoCoach` to something unique.
3. Pick a destination (**My Mac**, an iPad/iPhone connected by cable, or a simulator) and press **Run**.
   - On an iPhone/iPad the first run asks you to trust the developer profile:
     *Settings → General → VPN & Device Management*.
   - The iOS Simulator uses your Mac's microphone.
   - YouTube needs an internet connection.

If you prefer generating the project, `project.yml` describes the same project for
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen && xcodegen`).

## First practice session

1. **+** → paste a YouTube link (the title is filled in automatically).
2. Open the song. The **Game** tab needs the song's notes the first time: either tap *Listen to
   the video to make the game* (keep the room quiet and the volume up while the video plays once),
   or tap **Set up** and import a MIDI/MusicXML file.
3. Pick *Learn* or *Play*, a hand, *Keys* or *Notes*, and press **Start**. Try *Listen first* to
   hear it.
4. In the **Video** tab, press **Wait for me** or **Follow me** to have the video keep pace. The
   video mutes while the coach listens so the microphone hears the piano, not the video (change
   this in Settings if you use headphones or a MIDI keyboard). For sheet music in video mode, sync
   it in **Set up**: *The first note is here* + tempo, or *Tap along with the video…*.

Try it with `Samples/Ode to Joy (easy).musicxml` and any easy "Ode to Joy" piano tutorial.

## Things to say

| Playing | Speed | Music | Moving around | Coach |
|---|---|---|---|---|
| play / start / keep going | slower / slow down | show the music | go back / rewind | follow me |
| pause / stop / wait | faster / speed up | hide the music | skip ahead | wait for me |
| sound on / sound off | normal speed | | again / one more time | coach off |
| | half speed / speed 75 | | from the top / start over | what can I say |
| | | | measure twelve / bar 4 | |
| | | | loop this / stop looping | |

While the video's own sound is playing, start commands with "Coach" ("Coach, pause"), so a
teacher talking in the video can't trigger them. When the video is muted (the default while the
coach listens), plain commands work. In a noisy room, turn on *Settings → Only after "Coach"*.

## Tips

- **A MIDI keyboard is the most reliable input.** A digital piano connected by USB (iPad: USB-C or
  a Lightning camera adapter) or Bluetooth MIDI gives the exact notes, and the video's own sound
  can't confuse it.
- With the microphone, keep the video muted (the default) or use headphones for the video's sound.
- If the coach misses soft notes, raise *Sensitivity*. If it reacts to noise, lower it.
- *How far the video may get ahead* controls how strictly it waits: lower is stricter.

## How it works

```
microphone ─► onset detector ──┐                          ┌─► play / pause
(or MIDI keyboard)             ├─► score follower ─► pacer ┼─► playback speed
reference track ───────────────┘   (where is the child,    └─► jump to the child
 (learned from the video, or        how fast are they?)
  sheet music + sync)
```

- **Onset detection**: log-spectral flux ("SuperFlux") with an adaptive threshold finds each attack.
  The pitch content right after it is measured per piano key, with the energy that was already
  sounding subtracted so that held notes don't blur new ones.
- **Score following**: a hidden-Markov-model forward step over the reference track's events.
  Transitions favour the next note but allow wrong notes, skipped notes, repeats and restarts from a
  measure start. Emissions compare the heard pitch content with the expected notes. The child's
  speed comes from a robust (Theil–Sen) slope of *video time vs. real time* over recent notes.
- **Pacing**: the playback rate follows the child's speed plus a correction that closes the gap,
  quantised to the rates YouTube supports (0.25× steps) with a dwell time to avoid flapping. The
  video pauses when it gets ahead or the child goes quiet, and it seeks when the child jumps.

- **The game** (`GameEngine`): a playhead moves through the song's notes at the chosen speed.
  In *Learn* mode it stops at each chord until every required note is played. In *Play* mode,
  notes played within 0.1 s are *perfect*, within 0.25 s *good*, and later ones are *missed*.
  Every chord gives a "struggle" score (waiting long, playing late, missing or wrong notes count
  up; quick and on-time count down). When the last 8 chords average clearly high the speed drops
  15 %; when clearly low it rises 8 %. Microphone input is matched to the expected chord by its
  pitch content, while MIDI input is matched note by note.
- **Working out notes by listening** (`NoteTranscriber`): at each attack the strongest piano key
  is taken, checked against being the octave of a weaker bass note, and the energy its harmonics
  explain is subtracted before looking for the next note. On synthesized two-hand playing this
  gets about 89 % of notes right.

The engine is the Swift package in `Packages/PianoCoachCore`. It uses Foundation only and has more
than 200 unit tests, including end-to-end tests that synthesise piano audio of a "child" playing at
60 % speed and check that the follower keeps up. Run them with:

```sh
cd Packages/PianoCoachCore && swift test
```

## Limitations and notes

- **Only videos whose owners allow embedding** can play in the app (otherwise YouTube reports
  error 101/150; use *Open in YouTube*). Ads may play before some videos.
- YouTube's player supports speeds in 0.25 steps (0.25×…2×). Between steps the coach pauses briefly
  to stay with the child.
- YouTube's terms don't allow drawing over the player, so the sheet music appears **beside or
  below** the video rather than on top of it. This also keeps the pianist's hands visible.
- Repeats and first/second endings in MusicXML are followed. D.C./D.S./Coda jumps are not.
- The coach can't hear the video directly: it listens through the microphone. Learning a song
  works best with the device's speakers turned up in a quiet room.
- Everything runs on the device. Speech recognition uses on-device recognition when available.

## Project layout

```
PianoCoach.xcodeproj         Xcode project (one multiplatform target)
PianoCoach/                  App sources (SwiftUI, WebKit, AVFoundation, Speech, CoreMIDI)
  App/  Coach/  Audio/  Speech/  Player/  Sheet/  Views/
WebAssets/                   YouTube player page, sheet-music page, OpenSheetMusicDisplay
Packages/PianoCoachCore/     Pure-Swift engine + tests
Samples/                     Sample MusicXML
ThirdParty/                  Third-party licenses (OpenSheetMusicDisplay, BSD-3-Clause)
```

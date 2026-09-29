# Piano Coach

An iPhone, iPad and Mac app that helps a child practise piano with YouTube videos.
It listens to the child playing and **paces the video to them**. When they slow down, the video
slows down. When they stop, it waits. It never runs ahead. They can also **ask for the sheet
music** and follow a cursor that moves with them.

- **Wait for me** – the video pauses when the child stops playing and continues when they start
  again. Works with any video, no setup.
- **Follow me** – the coach knows where the child is in the piece and keeps the video at their
  position and speed. It slows the video, pauses it when it gets ahead, and jumps back when they
  restart a passage. It needs either a *learned* version of the song (the coach listens to the video
  once) or sheet music that has been synced to the video.
- **Voice commands** – "slower", "pause", "show the music", "go back", "measure twelve",
  "follow me"… (full list below). Recognition runs on the device.
- **Sheet music** – MusicXML (with a moving cursor; tap a measure to jump there), PDF or a photo,
  shown beside or below the video.
- **Note input** – the device's microphone, or (most accurate) a USB/Bluetooth MIDI keyboard.

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
2. Press **Wait for me** and let your child play along. The video mutes while the coach listens, so
   the microphone hears the piano rather than the video. Change this in Settings if you use
   headphones or a MIDI keyboard.
3. For **Follow me**, tap **Set up** and choose one:
   - **Teach the coach** → *Start listening*: the video plays once with the sound on while the coach listens
     (keep the room quiet and the volume up). Done.
   - **Sheet music**: import a MusicXML file (MuseScore → *Export → MusicXML*) or a MIDI file, then
     sync it to the video. Either press *The first note is here* when the first note plays and
     set the tempo, or use *Tap along with the video…*, tapping on the first beat of every measure while
     the video plays. PDFs and photos can be shown but not followed.
4. Say **"show the music"** or tap **Music** to see the sheet beside or below the video.

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

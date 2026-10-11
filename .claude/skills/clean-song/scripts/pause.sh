#!/bin/bash
# Pauses the video at a few moments and takes a screenshot of each, for lining the notes up with the
# video's clock (align.py) — a paused frame shows which keys are down at a known video time.
# Usage: pause.sh <video id> <work dir> <seconds> [seconds ...]   (SIM=... to choose the simulator)
VIDEO=$1; OUT=$2; shift 2
SIM=${SIM:-DD70A857-D383-4992-B7FD-D1008391D095}; APP=com.farhatnadim.PianoCoach
mkdir -p "$OUT/paused"
for T in "$@"; do
  xcrun simctl terminate "$SIM" $APP 2>/dev/null
  (xcrun simctl launch --console-pty "$SIM" $APP -play-video "$VIDEO" "$T" > "$OUT/paused/$T.log" 2>&1 &)
  sleep 16
  xcrun simctl io "$SIM" screenshot "$OUT/paused/$T.png" > /dev/null 2>&1
  sleep 1
  echo "asked $T s -> paused at $(grep 'PianoCoach: wall' "$OUT/paused/$T.log" | tail -1 | awk '{print $5}') s"
done
xcrun simctl terminate "$SIM" $APP

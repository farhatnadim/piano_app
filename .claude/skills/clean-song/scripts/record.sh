#!/bin/bash
# Records the simulator playing a YouTube tutorial from start to end, muted, inside Piano Coach.
# Usage: record.sh <video id> <work dir> [simulator id]
# Leaves <work dir>/screen.mp4, play.log (video time against wall time) and frame_times.txt.
set -e
VIDEO=$1; OUT=$2; SIM=${3:-DD70A857-D383-4992-B7FD-D1008391D095}
APP=com.farhatnadim.PianoCoach
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
mkdir -p "$OUT"
xcrun simctl boot "$SIM" 2>/dev/null || true
if [ -z "$SKIP_BUILD" ]; then
  xcodebuild -project "$ROOT/PianoCoach.xcodeproj" -scheme PianoCoach -destination "id=$SIM" \
    -derivedDataPath "$ROOT/build" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
  xcrun simctl install "$SIM" "$ROOT/build/Build/Products/Debug-iphonesimulator/PianoCoach.app"
fi
xcrun simctl terminate "$SIM" $APP 2>/dev/null || true
xcrun simctl io "$SIM" recordVideo --codec=h264 --force "$OUT/screen.mp4" > "$OUT/rec.log" 2>&1 &
REC=$!
sleep 1
xcrun simctl launch --console-pty "$SIM" $APP -play-video "$VIDEO" > "$OUT/play.log" 2>&1 &
LAUNCH=$!
# Until the player reports it ended (state 0), up to 10 minutes.
for i in $(seq 1 120); do
  sleep 5
  if grep "PianoCoach: wall" "$OUT/play.log" | tail -1 | tr -d '\r' | grep -q "state 0$"; then break; fi
done
sleep 2
kill -INT $REC; wait $REC 2>/dev/null || true
xcrun simctl terminate "$SIM" $APP; kill $LAUNCH 2>/dev/null || true
# Packet times are the frame times (no B-frames), and reading them needs no decoding.
ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$OUT/screen.mp4" | sort -n > "$OUT/frame_times.txt"
echo "frames: $(wc -l < "$OUT/frame_times.txt")"
echo "player states (1 playing, 2 paused, 3 buffering, 0 ended):"
grep "PianoCoach: wall" "$OUT/play.log" | tr -d '\r' | awk '{print $7}' | uniq -c | tr '\n' ' '; echo
echo "video ended at: $(grep 'PianoCoach: wall' "$OUT/play.log" | tail -1 | awk '{print $5}') s"

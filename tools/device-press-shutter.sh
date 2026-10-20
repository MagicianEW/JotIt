#!/usr/bin/env bash
#
# Takes a picture with the system camera.
#
# The camera is a different application, so a test inside JotIt cannot touch
# it — the test asks the platform for a picture and waits. This is the other
# half: it watches the window stack for the camera and taps the shutter when
# it shows up.
#
# The camera takes two taps, not one. The first opens the shutter; the app
# then shows the shot it just took, with a cross to throw it away and a tick
# to hand it over, and only after the tick does the photo go back to JotIt.
# Miss the second tap and the camera sits there holding a picture nobody
# asked for.
#
# Usage: tools/device-press-shutter.sh <device-id> <x> <y> [<confirm-x> <confirm-y>]

set -euo pipefail

DEVICE="${1:?usage: device-press-shutter.sh <device-id> <x> <y> [<confirm-x> <confirm-y>]}"
X="${2:?usage: device-press-shutter.sh <device-id> <x> <y> [<confirm-x> <confirm-y>]}"
Y="${3:?usage: device-press-shutter.sh <device-id> <x> <y> [<confirm-x> <confirm-y>]}"
CONFIRM_X="${4:-}"
CONFIRM_Y="${5:-}"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"

for _ in $(seq 1 180); do
  focus="$("$ADB" -s "$DEVICE" shell dumpsys window 2>/dev/null \
    | grep mCurrentFocus | tail -1)"
  case "$focus" in
  *camera*|*Camera*)
    # Give the viewfinder a moment to settle before the shutter.
    sleep 3
    "$ADB" -s "$DEVICE" shell input tap "$X" "$Y"
    echo "shutter pressed at $X,$Y"
    if [ -n "$CONFIRM_X" ]; then
      sleep 5
      "$ADB" -s "$DEVICE" exec-out screencap -p >/tmp/jotit_camera_confirm.png 2>/dev/null || true
      "$ADB" -s "$DEVICE" shell input tap "$CONFIRM_X" "$CONFIRM_Y"
      echo "confirmed at $CONFIRM_X,$CONFIRM_Y"
    fi
    exit 0
    ;;
  esac
  sleep 1
done

echo "the camera never came to the foreground" >&2
exit 1

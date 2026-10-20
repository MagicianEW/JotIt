#!/usr/bin/env bash
#
# Picks a file in the system document picker.
#
# Like the camera shutter, the document picker is another application: JotIt
# asks for a file and waits, and this script does the tapping on the host.
#
# The route through the picker is walked the same way every time, so that the
# test does not depend on whatever happens to be in the user's folders:
#
#   1. the drawer, which is the only way into the storage roots
#   2. 「图片」 — the images root, which lists the image *folders*
#   3. 「JotItTest」 — the folder this test owns; nothing else is in it
#   4. the one image in it
#
# Tapping the image ends the picker: ACTION_OPEN_DOCUMENT in single-select
# mode hands the file straight back to the app that asked for it.
#
# Usage: tools/device-pick-file.sh <device-id>

set -euo pipefail

DEVICE="${1:?usage: device-pick-file.sh <device-id>}"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"

shot() {
  "$ADB" -s "$DEVICE" exec-out screencap -p >"/tmp/jotit_picker_$1.png" 2>/dev/null || true
}

tap() {
  "$ADB" -s "$DEVICE" shell input tap "$1" "$2"
  sleep 3
}

for _ in $(seq 1 180); do
  focus="$("$ADB" -s "$DEVICE" shell dumpsys window 2>/dev/null \
    | grep mCurrentFocus | tail -1)"
  case "$focus" in
  *documentsui*|*DocumentsUI*|*picker*|*Picker*)
    shot 1_recent
    tap 77 172      # the drawer
    shot 2_drawer
    tap 214 486     # 「图片」 — the images root
    shot 3_images
    tap 754 740     # 「JotItTest」 — the folder this test owns
    shot 4_folder
    tap 202 823     # the one image in it
    echo "the file was picked"
    exit 0
    ;;
  esac
  sleep 1
done

echo "the document picker never came to the foreground" >&2
exit 1

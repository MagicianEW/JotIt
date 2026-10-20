#!/usr/bin/env bash
#
# Runs an integration test on a real Android device **without uninstalling
# the app**.
#
# `flutter drive` cannot be used here. Its `DriveService.stop()` calls
# `uninstallApp` unconditionally (flutter_tools/lib/src/drive/drive_service.dart),
# and on a MIUI device it is the *fresh* install that triggers the "install
# over USB" confirmation the user has to answer by hand — an overwrite does
# not. So the rule this script exists to enforce is simple: never uninstall,
# and never let a tool do it behind our back.
#
# The run therefore goes:
#
#   1. build the APK with the test as its entry point
#   2. `adb install -r -t` — overwrite, keep the data, no prompt
#   3. start the app
#   4. read the VM service URI the engine announces, and forward that port
#   5. run the driver script by hand, pointed at the same VM service
#
# Note what is *not* here: `flutter attach`. It looks like the polite way to
# pick up the VM service, but it is not:
#
#   * `flutter attach` performs a devFS sync, which compiles `lib/main.dart`
#     and pushes that kernel into the app's `app_flutter/` directory, then
#     restarts the app. The test would then be running the app, not the test.
#   * The restart replaces the VM service: a new port and a new auth token.
#     The driver, which was handed the old URL, would wait forever for a
#     service that no longer exists.
#
# Starting the app with `am start` needs none of that: the debug APK already
# carries the test's kernel inside it, and the engine announces its own VM
# service URI on startup.
#
# Usage: tools/run-device-test.sh <device-id> <target-file>

set -euo pipefail

DEVICE="${1:?usage: run-device-test.sh <device-id> <target-file>}"
TARGET="${2:?usage: run-device-test.sh <device-id> <target-file>}"
PACKAGE="com.jotit.jotit"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
DRIVER_LOG="/tmp/jotit_device_driver.log"

cd "$(dirname "$0")/.."

cleanup() {
  # Stop the helper processes, but leave the app installed: uninstalling is
  # the one thing this script must never do.
  pkill -f "device-press-shutter.sh" 2>/dev/null || true
  pkill -f "device-pick-file.sh" 2>/dev/null || true
  "$ADB" -s "$DEVICE" shell am force-stop "$PACKAGE" 2>/dev/null || true
}
trap cleanup EXIT

if ! "$ADB" -s "$DEVICE" shell pm list packages 2>/dev/null | grep -q "$PACKAGE"; then
  echo "The app is not installed, and a fresh install needs a confirmation on" >&2
  echo "this device. Install it once by hand; after that this script only" >&2
  echo "ever overwrites it." >&2
  exit 1
fi

echo "==> building the test APK"
flutter build apk --debug --target="$TARGET"

echo "==> overwriting the app (no uninstall, so no prompt on the device)"
"$ADB" -s "$DEVICE" install -r -t build/app/outputs/flutter-apk/app-debug.apk

"$ADB" -s "$DEVICE" shell pm grant "$PACKAGE" android.permission.RECORD_AUDIO 2>/dev/null || true

# The debug build unpacks its assets into the app's data directory before it
# runs. `flutter attach` overwrites that copy with a kernel it compiled
# itself — from `lib/main.dart` — so the app would start running the app
# instead of the test. Throwing the copy away makes sure the kernel inside
# the APK is the one that runs.
"$ADB" -s "$DEVICE" shell run-as "$PACKAGE" rm -rf app_flutter 2>/dev/null || true

echo "==> starting the app"
# The app has to be *restarted*: an app that is already running is only
# brought to the foreground, and the engine announces its VM service once,
# at startup. Starting it again without stopping it first would leave this
# script waiting for a line that is never printed.
#
# `--activity-clear-task` is not optional. The system camera gets pulled into
# *this app's* task stack (it has no task affinity of its own, so it lands in
# whichever task launched it), and it sits on top of MainActivity there. After
# a force-stop that camera activity is still the top of the task, so a plain
# `am start` matches LAUNCH_SINGLE_TOP, brings the *task* to the front — which
# shows the camera, not this app — and the app never starts at all. Clearing
# the task throws that stale activity away and gives MainActivity the task
# back.
#
# The start is checked and retried because a package that was just
# overwritten can refuse to launch for a moment while the system finishes
# replacing it, and the failure is invisible unless the output is kept.
"$ADB" -s "$DEVICE" shell am force-stop "$PACKAGE" 2>/dev/null || true
sleep 2
"$ADB" -s "$DEVICE" logcat -c 2>/dev/null || true

started=0
for attempt in 1 2 3 4 5; do
  "$ADB" -s "$DEVICE" shell am start -S --activity-clear-task \
    -n "$PACKAGE/.MainActivity" 2>&1 | head -3
  sleep 6
  if "$ADB" -s "$DEVICE" shell pidof "$PACKAGE" 2>/dev/null | grep -q .; then
    started=1
    break
  fi
  echo "    the app did not come up; trying again"
  sleep 4
done

if [ "$started" -ne 1 ]; then
  echo "the app would not start" >&2
  "$ADB" -s "$DEVICE" logcat -d 2>/dev/null | grep -aiE "FATAL|AndroidRuntime" | tail -10 >&2
  exit 1
fi

# The engine announces its own VM service URI on startup. Waiting for that
# line is more reliable than guessing a port: the forward then has something
# concrete to connect to, and the driver can use the very same URI.
echo "==> waiting for the app to announce its VM service"
VM_URL=""
for _ in $(seq 1 120); do
  VM_URL="$("$ADB" -s "$DEVICE" logcat -d 2>/dev/null \
    | grep -oE 'Dart VM service is listening on http://127\.0\.0\.1:[0-9]+/[^ ]*' \
    | tail -1 | sed 's/.*listening on //')"
  if [ -n "$VM_URL" ]; then break; fi
  sleep 1
done

if [ -z "$VM_URL" ]; then
  echo "the app never announced a VM service" >&2
  "$ADB" -s "$DEVICE" logcat -d 2>/dev/null | grep -aiE "FATAL|AndroidRuntime" | tail -10 >&2
  exit 1
fi
echo "    $VM_URL"

VM_PORT="$(echo "$VM_URL" | grep -oE '127\.0\.0\.1:[0-9]+' | cut -d: -f2)"

# Where the VM service actually listens depends on how the app was started.
#
# `flutter run` launches the app with an "observatory port" extra, and the
# engine then opens the VM service on the *abstract* socket
# `flutter_vm_service` — that is the socket `adb forward localabstract:`
# expects. An app started with a plain `am start` has no such extra: the
# engine opens an ordinary TCP port on the device's own loopback, and prints
# that port in the URI it announces. Forwarding to the abstract socket then
# points at a socket nobody is listening on, and every request comes back
# empty — the driver waits forever for a service that was never there.
#
# So: forward to the device's TCP port, and check that something actually
# answers before handing the URL to the driver.
"$ADB" -s "$DEVICE" forward --remove "tcp:$VM_PORT" >/dev/null 2>&1 || true
"$ADB" -s "$DEVICE" forward "tcp:$VM_PORT" "tcp:$VM_PORT" >/dev/null

if ! curl -s --max-time 10 "$VM_URL" >/dev/null 2>&1; then
  echo "    the device TCP port did not answer; trying the abstract socket" >&2
  "$ADB" -s "$DEVICE" forward --remove "tcp:$VM_PORT" >/dev/null 2>&1 || true
  "$ADB" -s "$DEVICE" forward "tcp:$VM_PORT" "localabstract:flutter_vm_service" >/dev/null
  if ! curl -s --max-time 10 "$VM_URL" >/dev/null 2>&1; then
    echo "the VM service did not answer on $VM_URL" >&2
    exit 1
  fi
fi

echo "==> running the driver"
# Some of what a phone test needs to touch lives in another application — the
# system camera, for one. A test inside the app cannot reach it, so the host
# can run a helper alongside: set DEVICE_HELPER to a command and it runs
# while the test waits.
HELPER_PID=""
if [ -n "${DEVICE_HELPER:-}" ]; then
  echo "    helper: $DEVICE_HELPER"
  # shellcheck disable=SC2086
  eval "$DEVICE_HELPER" &
  HELPER_PID=$!
fi

set +e
VM_SERVICE_URL="$VM_URL" dart run test_driver/integration_test.dart 2>&1 | tee "$DRIVER_LOG"
STATUS=${PIPESTATUS[0]}
set -e

if [ -n "$HELPER_PID" ]; then
  kill "$HELPER_PID" 2>/dev/null || true
  wait "$HELPER_PID" 2>/dev/null || true
fi

exit "$STATUS"

#!/usr/bin/env bash
#
# Verifies the macOS build the same way the Windows and Android ones were
# verified: by looking at the product, not at the source.
#
# Two of the three fixes in this port are things Xcode will happily build
# either way — a missing ATS exception and a sandboxed Release build both
# produce a perfectly good .app that cannot reach a network. Reading the
# sources proves nothing; `codesign` and `PlistBuddy` prove it.
#
# Usage:
#   export JOTIT_DAV_URL=http://192.168.1.100:35115/webDAV
#   export JOTIT_DAV_USER=EW
#   export JOTIT_DAV_PASS='...'
#   bash tools/verify-macos.sh
#
# Without the three JOTIT_DAV_* variables the GUI stage is skipped rather than
# failed — the server is a LAN address that will not be there on a laptop in a
# café.

set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/macos/Build/Products/Release/JotIt.app"

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

FAILED=0

say '1. toolchain'
command -v flutter >/dev/null || { bad 'flutter is not on PATH'; exit 1; }
ok "flutter $(flutter --version | head -1 | awk '{print $3}')"
xcode-select -p >/dev/null 2>&1 || { bad 'no active Xcode (xcode-select -p fails)'; exit 1; }
ok "Xcode $(xcodebuild -version | head -1 | awk '{print $2}')"

say '2. analysis and tests'
# `dart analyze`, not `flutter analyze`: the label has always said so, and
# `flutter analyze` dies with a FormatException on a path that is not pure
# ASCII (the LSP frame carries the workspace path, and the Chinese directory
# name breaks the parser). The static analysis is identical; only the
# wrapper differs.
if dart analyze; then ok 'dart analyze clean'; else bad 'dart analyze'; fi
if flutter test; then ok 'flutter test'; else bad 'flutter test'; fi

say '3. release build'
if flutter build macos --release; then
  ok 'built Release/JotIt.app'
else
  bad 'flutter build macos --release'
  exit 1
fi

say '4. what actually got built'

# --- ATS -------------------------------------------------------------------
# A cleartext LAN server is the normal case for a self-hosted box, so the
# local-networking exception has to be present in the shipped Info.plist.
ATS=$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsLocalNetworking' \
        "$APP/Contents/Info.plist" 2>/dev/null)
if [ "$ATS" = "true" ]; then
  ok 'ATS allows local networking (192.168.x is inside 192.168.0.0/16)'
else
  bad "ATS NSAllowsLocalNetworking = '${ATS:-missing}' — a sync to an http:// NAS will be blocked"
fi

# --- sandbox ---------------------------------------------------------------
# If the sandbox is on, ~/Documents is redirected into the app container and
# the user's notes become invisible in Finder. That is the whole premise.
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q 'app-sandbox</key>[[:space:]]*<true/>'; then
  bad 'Release build is sandboxed — the vault lands in ~/Library/Containers and is not "ordinary files"'
else
  ok 'Release build is not sandboxed (vault stays in the real ~/Documents)'
fi

# --- name ------------------------------------------------------------------
NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP/Contents/Info.plist" 2>/dev/null)
if [ "$NAME" = "JotIt" ]; then
  ok 'CFBundleName is JotIt'
else
  bad "CFBundleName is '${NAME:-unknown}' — the Dock and the firewall prompt will show it"
fi

say '5. GUI, against a real server'
# The same full-UI path the Windows run used: location gate → new note →
# type → Ctrl+S → settings → add remote → sync → read the bytes back over
# HTTP → delete what it wrote.
#
# Without a NAS to point at, the bundled test server stands in. A stage that
# is skipped on every machine but the author's is a stage that catches
# nothing — and this one is what catches the GUI path breaking, which is the
# part the unit suite cannot reach at all.
DAV_PID=''
DAV_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jotit_dav.XXXXXX")"
cleanup_dav() {
  if [ -n "$DAV_PID" ]; then kill "$DAV_PID" 2>/dev/null; fi
  rm -rf "$DAV_ROOT"
}
trap cleanup_dav EXIT

if [ -z "${JOTIT_DAV_URL:-}" ] || [ -z "${JOTIT_DAV_USER:-}" ] || [ -z "${JOTIT_DAV_PASS:-}" ]; then
  if ! command -v node >/dev/null; then
    printf '  \033[33mSKIP\033[0m no JOTIT_DAV_* and no node for the bundled test server\n'
  else
    # `--port 0` lets the OS pick a free port, and the server prints the one
    # it got. A hard-coded port is a coin toss: if something else is already
    # listening there, the server cannot bind and the test ends up talking to
    # a stranger — or to nothing, which looks exactly like a broken client.
    node tools/webdav-test-server.mjs --root "$DAV_ROOT" --port 0 \
      >"$DAV_ROOT/server.log" 2>&1 &
    DAV_PID=$!
    # Out of the shell's job table: otherwise the cleanup kill reports
    # "Terminated: 15 node ..." on stderr and the run looks like it failed.
    disown "$DAV_PID" 2>/dev/null || true
    DAV_URL=''
    for _ in $(seq 1 40); do
      DAV_URL=$(sed -n 's/.*endpoint  *\(http:\/\/[^ ]*\).*/\1/p' \
                "$DAV_ROOT/server.log" 2>/dev/null | head -1)
      if [ -n "$DAV_URL" ]; then break; fi
      sleep 0.25
    done
    if [ -z "$DAV_URL" ]; then
      bad 'the bundled test server did not come up'
    else
      export JOTIT_DAV_URL="${DAV_URL%/}"
      export JOTIT_DAV_USER=testuser
      export JOTIT_DAV_PASS=test
      ok "using the bundled test server at $JOTIT_DAV_URL"
    fi
  fi
fi

if [ -n "${JOTIT_DAV_URL:-}" ]; then
  if flutter drive \
      --driver=test_driver/integration_test.dart \
      --target=integration_test/nas_gui_test.dart \
      -d macos; then
    ok 'flutter drive -d macos'
  else
    bad 'flutter drive -d macos'
  fi
else
  printf '  \033[33mSKIP\033[0m no WebDAV server to point the GUI test at\n'
fi

say 'result'
if [ "$FAILED" -eq 0 ]; then
  printf '  \033[32mall checks passed\033[0m\n'
else
  printf '  \033[31mthere are failures above — read them, do not ship\033[0m\n'
fi
exit "$FAILED"

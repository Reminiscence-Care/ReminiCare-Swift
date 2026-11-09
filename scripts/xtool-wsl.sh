#!/usr/bin/env bash
# Build and install the app on a USB-connected iPad with xtool from WSL.
#
#   scripts/xtool-wsl.sh            # = xtool dev run (build, install, launch)
#   scripts/xtool-wsl.sh build --ipa
#
# From Windows, call this file rather than pasting its commands into
# `wsl.exe -- bash -c "..."`: wsl.exe expands $variables to empty strings
# first, which once turned the cleanup below into `find` on the repo itself.
#
# The iPad stays connected to Windows (not usbipd); see scripts/usbmuxd_relay.py.
# Needs: Apple Mobile Device Service running on Windows (from iTunes / Apple
# Devices), the iPad trusting this PC, and Python on Windows.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$HOME/reminicare-xtool"
port=27115   # relay port in WSL; never 27015, see scripts/usbmuxd_relay.py

# 1. Windows must own the iPad; usbipd passthrough stalls on large transfers.
if command -v usbipd.exe >/dev/null && usbipd.exe list 2>/dev/null | grep -q '05ac:.*Attached'; then
    echo "Detaching iPad from WSL so Windows can reach it..."
    usbipd.exe detach --hardware-id 05ac:12ab >/dev/null 2>&1 || true
    sleep 3
fi

# 2. Relay Windows' usbmuxd (127.0.0.1:27015 on Windows) into WSL on $port.
if ! python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 1)" 2>/dev/null; then
    win_python="${WINDOWS_PYTHON:-$(cmd.exe /c where python.exe 2>/dev/null | tr -d '\r' | grep -iv WindowsApps | head -n1)}"
    [ -n "$win_python" ] || { echo "Python for Windows not found; set WINDOWS_PYTHON to its path." >&2; exit 1; }
    win_python="$(wslpath -u "$win_python")"
    mkdir -p "$HOME/.cache"
    nohup python3 "$repo/scripts/usbmuxd_relay.py" listen "$win_python" \
        "$(wslpath -w "$repo/scripts/usbmuxd_relay.py")" >"$HOME/.cache/usbmuxd-relay.log" 2>&1 &
    sleep 1
fi
export USBMUXD_SOCKET_ADDRESS="127.0.0.1:$port"

# 3. Build from a copy on the Linux filesystem: faster than /mnt, and xtool's
#    final move of the .app fails across filesystems or when Windows locks it.
case "$work" in
    ""|/|"$HOME"|"$repo"|"$repo"/*) echo "Refusing to use '$work' as the build copy." >&2; exit 1 ;;
esac
mkdir -p "$work"
find "$work" -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +   # keep the build cache only
(cd "$repo" && tar --exclude=./.git --exclude=./xtool --exclude=./build --exclude='*/.build' --exclude=./.build \
    --exclude=./report-worker --exclude=./speech-worker -cf - .) \
    | (cd "$work" && tar -xf -)

# 4. Stamp the commit into the app so problem reports say which code is running.
commit="$(git -c safe.directory='*' -C "$repo" rev-parse --short HEAD 2>/dev/null || echo unknown)"
# The checkout belongs to Windows git (core.autocrlf=true, CRLF files), and on
# /mnt/d every file looks executable; match both or every file counts as changed.
if [ "$commit" != unknown ] && ! git -c safe.directory='*' -c core.filemode=false -c core.autocrlf=true \
        -C "$repo" diff --quiet HEAD -- 2>/dev/null; then
    commit="$commit-dirty"
fi
sed -i "s|<key>CFBundleDisplayName</key>|<key>ReminiCareCommit</key>\n\t<string>$commit</string>\n\t<key>CFBundleDisplayName</key>|" \
    "$work/Config/xtool-Info.plist"
echo "Commit stamped into the app: $commit"
cd "$work"
exec xtool dev "$@"

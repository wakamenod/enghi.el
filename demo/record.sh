#!/usr/bin/env bash
# Record a demonstration of this checkout, in the user's own configuration.
#
#   demo/record.sh <scene> [out.mp4]
#
# Starts a throwaway enghi server (never the resident one on 7777, never
# ~/.local/share/enghi), opens a second GUI Emacs with ~/.emacs.d/init.el
# and this checkout's enghi.el in front of the one the init loads, plays
# demo/scenes/<scene>.{el,sh} and records the frame's own window.
#
# Adapted from emacs-claude-code's demo/record.sh; its README says what
# the recorder needs (macOS, Screen Recording permission, an unlocked
# screen).  ENGHI_BIN picks the server binary (default: the sibling enghi
# checkout's bin/enghi, which has to be built from a version with the
# work log), DEMO_PORT the port it listens on.
set -euo pipefail

scene=${1:?usage: demo/record.sh <scene> [out.mp4]}
here=$(cd "$(dirname "$0")" && pwd)
checkout=$(cd "$here/.." && pwd)
out=${2:-$here/$scene.mp4}
scene_el=$here/scenes/$scene.el
scene_sh=$here/scenes/$scene.sh
[ -f "$scene_el" ] || { echo "no such scene: $scene_el" >&2; exit 1; }
[ -f "$scene_sh" ] || { echo "no such scene: $scene_sh" >&2; exit 1; }

emacs_app=${EMACS_APP:-/opt/homebrew/Cellar/emacs-plus@32/32.0.50/Emacs.app}
emacsclient=${EMACSCLIENT:-$(command -v emacsclient || echo "${emacs_app%/*}/bin/emacsclient")}
enghi_bin=${ENGHI_BIN:-$HOME/Projects/SideProjects/enghi/bin/enghi}
port=${DEMO_PORT:-7798}
[ "$port" != 7777 ] || { echo "7777 is the resident server; pick another DEMO_PORT" >&2; exit 1; }
[ -x "$enghi_bin" ] || { echo "no enghi binary at $enghi_bin (make build there)" >&2; exit 1; }

tag=enghi-$(basename "$checkout")-$scene
server=enghi-demo-$(printf '%s' "$scene" | cut -c1-12)-$(printf '%s' "$tag" | md5 -q | cut -c1-6)
ready=/tmp/enghi-demo-$tag-ready.txt
title="enghi demo: $tag"
data=${TMPDIR:-/tmp}/enghi-demo-$tag
fps=${DEMO_FPS:-10}
width=${DEMO_WIDTH:-1456}
recorder=$here/.build/record-window

for variable in $(env | sed -n 's/^\(CLAUDE[A-Z_]*\)=.*/\1/p'); do
    unset "$variable"
done

recorder_pid=
enghi_pid=
cleanup() {
    if [ -n "$recorder_pid" ]; then
        kill -INT "$recorder_pid" 2>/dev/null || true
        wait "$recorder_pid" 2>/dev/null || true
    fi
    pkill -f "$server" 2>/dev/null || true
    if [ -n "$enghi_pid" ]; then
        kill "$enghi_pid" 2>/dev/null || true
        wait "$enghi_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if pgrep -f "$server" >/dev/null 2>&1; then
    echo "a run of $scene from this checkout is already up; clear a dead one with: pkill -f $server" >&2
    exit 1
fi
if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $port is taken; set DEMO_PORT" >&2
    exit 1
fi
rm -f "$ready" "${TMPDIR:-/tmp}/emacs$(id -u)/$server"

if [ ! -x "$recorder" ] || [ "$here/record-window.swift" -nt "$recorder" ]; then
    echo "building $recorder" >&2
    mkdir -p "$here/.build"
    swiftc -O -parse-as-library -o "$recorder" "$here/record-window.swift" \
        2>&1 | grep -v "^ld: warning" || true
fi
[ -x "$recorder" ] || { echo "could not build $recorder" >&2; exit 1; }

# A fresh, throwaway server for every run
rm -rf "$data"
mkdir -p "$data"
cat > "$data/config.toml" <<TOML
db_path = "$data/enghi.db"
export_dir = "$data/export"
backup_dir = "$data/backup"
backup_enabled = false
skills_dir = "$data/skills"
TOML
"$enghi_bin" serve --config "$data/config.toml" --port "$port" >"$data/serve.log" 2>&1 &
enghi_pid=$!
for _ in $(seq 1 30); do
    curl -sf "http://127.0.0.1:$port/api/status" >/dev/null && break
    sleep 0.5
done
curl -sf "http://127.0.0.1:$port/api/status" >/dev/null || { echo "enghi did not start" >&2; exit 1; }

player=${TMPDIR:-/tmp}/enghi-demo-player-$scene.el
cp "$here/demo.el" "$player"

open -n -a "$emacs_app" --args -Q \
     --eval "(setq demo-scene-file \"$scene_el\" demo-server-name \"$server\" demo-ready-file \"$ready\" demo-frame-title \"$title\" demo-checkout \"$checkout\" demo-enghi-url \"http://127.0.0.1:$port\")" \
     -l "$player"

for _ in $(seq 1 60); do [ -f "$ready" ] && break; sleep 1; done
[ -f "$ready" ] || { echo "the demo Emacs never came up" >&2; exit 1; }
echo "enghi.el loaded from / server:" >&2
cat "$ready" >&2
echo "emacs server: $server" >&2

caffeinate -d -w $$ &
"$recorder" --title "$title" --out "$out" --fps "$fps" --width "$width" &
recorder_pid=$!
sleep 3
kill -0 "$recorder_pid" 2>/dev/null || { "$recorder" --list >&2; exit 1; }

e() {
    echo "-- $1" >&2
    if ! timeout 25 "$emacsclient" -s "$server" -e "$1" >/dev/null; then
        echo "   (no answer in 25s)" >&2
    fi
}
say() { e "(demo-say \"$1\")"; }

# shellcheck source=/dev/null
. "$scene_sh"

kill -INT "$recorder_pid" 2>/dev/null || true
wait "$recorder_pid" 2>/dev/null || true
recorder_pid=
echo "wrote $out" >&2
ls -lh "$out" >&2

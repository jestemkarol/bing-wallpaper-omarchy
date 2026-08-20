#!/bin/bash

# The finding this covers is not about parsing: it is about what a Text element
# does when it draws. QML's default textFormat is Text.AutoText, and Qt's
# rich-text heuristic turns a value that looks like markup into a document, so
# an <img src="http://host/x"> in a Bing title is fetched the moment the panel
# appears. No click, no interaction.
#
# So this test renders. It stands up a local HTTP server, draws the two shapes
# the plugin actually uses, and asserts the server was never asked for
# anything. Run offscreen, so no window appears.
#
# Skipped, not failed, where qml6 is missing: the sync and model suites carry
# the parsing side, and this needs a Qt runtime that a CI container may not
# have.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; passed=$((passed + 1)); }
nope() { printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; failed=$((failed + 1)); }
is() {
  local label="$1" actual="$2" expected="$3"
  [[ $actual == "$expected" ]] && ok "$label" || nope "$label" "expected '$expected', got '$actual'"
}

# Records every path it is asked for and answers 404, so a fetch is visible
# whether or not the resource exists.
# Records every path it is asked for and answers 404, so a fetch is visible
# whether or not the resource exists. Each hit is appended and flushed as it
# arrives, so the caller can stop the server the moment the render is done
# rather than sleeping long enough to be sure.
cat > "$WORK/server.py" <<'SERVER'
import http.server, socketserver, sys

log = open(sys.argv[1] + "/hits", "a", buffering=1)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        log.write(self.path + "\n")
        self.send_response(404)
        self.end_headers()
    def log_message(self, *a):
        pass

server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1] + "/port", "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
SERVER

# Renders one Text and reports what the server was asked for. $1 is the QML
# body of the Text, with @URL@ standing in for the served address. The scene
# quits itself once it has had time to draw and load, so the wait is bounded by
# the render rather than by a fixed sleep.
rendered_hits() {
  local body="$1"
  rm -f "$WORK/port" "$WORK/hits"
  : > "$WORK/hits"
  python3 "$WORK/server.py" "$WORK" &
  local server=$!
  for _ in $(seq 1 50); do
    [[ -s $WORK/port ]] && break
    sleep 0.1
  done
  [[ -s $WORK/port ]] || { kill "$server" 2>/dev/null; echo "server did not start"; return; }

  local url="http://127.0.0.1:$(cat "$WORK/port")/pulled.png"
  {
    printf 'import QtQuick\nItem {\n  width: 400; height: 200\n'
    printf '  %s\n' "${body//@URL@/$url}"
    printf '  Timer { interval: 1500; running: true; onTriggered: Qt.quit() }\n}\n'
  } > "$WORK/case.qml"
  QT_QPA_PLATFORM=offscreen timeout 10 qml6 "$WORK/case.qml" >/dev/null 2>&1
  kill "$server" 2>/dev/null
  wait "$server" 2>/dev/null
  tr -d '\n' < "$WORK/hits"
}

echo
echo "render (Text.AutoText and remote resources)"

# The source audit runs everywhere, including where qml6 is absent: it is what
# catches a textFormat being dropped from Panel.qml itself, which the generic
# elements below cannot see.
audit=$(python3 "$HERE/textformat-audit.py" "$HERE/../Panel.qml" 2>&1)
if [[ $? -eq 0 ]]; then
  ok "every dynamic Text in the panel pins textFormat"
else
  nope "every dynamic Text in the panel pins textFormat" "$audit"
fi

if ! command -v qml6 >/dev/null; then
  echo "  skip  qml6 not installed, the rendering cases below were not run"
  echo
  printf '%d passed, %d failed\n' "$passed" "$failed"
  (( failed == 0 ))
  exit $?
fi

# The control. Without this the rest proves nothing: if the harness could not
# make a Text fetch at all, every assertion below would pass for free.
is "an unpinned Text does fetch a remote image" \
   "$(rendered_hits 'Text { width: parent.width; text: "<img src=\"@URL@\">" }')" \
   "/pulled.png"

# The panel's shape after the fix.
is "a pinned Text does not" \
   "$(rendered_hits 'Text { width: parent.width; textFormat: Text.PlainText; text: "<img src=\"@URL@\">" }')" \
   ""

# The tooltip's shape, which the plugin cannot pin because the Text belongs to
# Omarchy, fed the value Model.displayText produces.
is "an unpinned Text is safe once the value is defused" \
   "$(rendered_hits 'Text { width: parent.width; text: "img src=\"@URL@\"" }')" \
   ""

# The entity form, which fires the same heuristic with no bracket present.
is "an entity reference is safe once defused" \
   "$(rendered_hits 'Text { width: parent.width; text: "Sunrise &ltimg src=\"@URL@\"" }')" \
   ""

echo
printf '%d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))

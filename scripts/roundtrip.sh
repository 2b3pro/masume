#!/bin/bash
# The agent-human round trip from a shell, against the built app: read the
# document, resolve cells, add an arrow, move it (as the human would), read
# it back, undo and redo, then kill the app and confirm recovery brings the
# document back at the same revision. Acceptance criteria 6, 7, 10, 11 of
# docs/agent-collaborative-annotation-spec.md. Integration test; not part
# of `swift test`.
#
#   bash scripts/build-app.sh && bash scripts/roundtrip.sh [image]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Masume.app"
IMAGE="${1:-$ROOT/Resources/AppIcon.png}"
[[ -d "$APP" ]] || { echo "error: build the app first ($APP missing)" >&2; exit 1; }

cd "$ROOT"
swift build -c release --product MasumeTool >/dev/null
CLI="$(swift build -c release --show-bin-path)/MasumeTool"
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

pkill -x Masume 2>/dev/null || true
sleep 1
open -a "$APP" "$IMAGE"
sleep 2

echo "==> 1. read the document"
DOC=$("$CLI" doc | field "d['result']['id']")
REV=$("$CLI" doc | field "d['result']['revision']")
echo "document $DOC at revision $REV"

echo "==> 2. resolve B3 and D6"
B3=$("$CLI" resolve B3 | field "d['result']['center']")
D6=$("$CLI" resolve D6 | field "d['result']['center']")
echo "B3 center $B3, D6 center $D6"

echo "==> 3. the agent adds an arrow with a reason"
OUT=$("$CLI" add arrow from=B3 to=D6 --doc "$DOC" --revision "$REV" --actor nova --actor-name Nova --reason "point at the button")
ARROW=$(echo "$OUT" | field "d['result']['element']['id']")
REV=$(echo "$OUT" | field "d['result']['revision']")
echo "arrow $ARROW, revision $REV"

echo "==> 4. the human moves it (a plain edit, no actor)"
OUT=$("$CLI" update "$ARROW" end=600,600 --doc "$DOC" --revision "$REV" --actor human --actor-name Human)
REV=$(echo "$OUT" | field "d['result']['revision']")
END=$("$CLI" element "$ARROW" | field "d['result']['element']['end']")
echo "agent reads it back: end $END at revision $REV"
[[ "$("$CLI" element "$ARROW" | field "d['result']['element']['end'] == {'x': 600, 'y': 600}")" == "True" ]]

echo "==> 5. a stale revision changes nothing"
"$CLI" delete "$ARROW" --doc "$DOC" --revision 0 >/dev/null && { echo "expected a conflict" >&2; exit 1; } || [[ $? -eq 2 ]]
[[ "$("$CLI" doc | field "d['result']['elementCount']")" == "1" ]]

echo "==> 6. either participant undoes and redoes"
"$CLI" undo --actor nova --actor-name Nova >/dev/null
END=$("$CLI" element "$ARROW" | field "d['result']['element']['end']")
echo "after undo: end $END"
[[ "$END" == "$D6" ]]
"$CLI" redo >/dev/null
REV=$("$CLI" doc | field "d['result']['revision']")
echo "after redo: revision $REV"

echo "==> 7. history names both"
"$CLI" history | field "[(e['actor']['name'], e['summary'], e.get('reason')) for e in d['result']['entries']]"

echo "==> 8. kill the app; recovery must bring the document back as it was"
pkill -x Masume
sleep 1
open -a "$APP"
sleep 3
AFTER_DOC=$("$CLI" doc | field "d['result']['id']")
AFTER_REV=$("$CLI" doc | field "d['result']['revision']")
AFTER_END=$("$CLI" element "$ARROW" | field "d['result']['element']['end']")
echo "recovered $AFTER_DOC at revision $AFTER_REV, arrow end $AFTER_END"
[[ "$AFTER_DOC" == "$DOC" && "$AFTER_REV" == "$REV" ]]
[[ "$("$CLI" element "$ARROW" | field "d['result']['element']['end'] == {'x': 600, 'y': 600}")" == "True" ]]

echo "==> 9. offline export of a saved copy matches the app's export"
TMP="$(mktemp -d)"
"$CLI" save "$TMP/Round.masume" >/dev/null
"$CLI" export "$TMP/live.png" --bounds clipToImage >/dev/null
"$CLI" export "$TMP/Round.masume" "$TMP/offline.png" --bounds clipToImage >/dev/null
cmp "$TMP/live.png" "$TMP/offline.png"
echo "byte-identical"
rm -rf "$TMP"

echo "PASS"

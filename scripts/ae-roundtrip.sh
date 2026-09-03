#!/bin/bash
# Apple Event round trip against the built app: read the active document's
# properties, then call execute for a create, a conflict, and a base-image
# crop, checking the envelope. Integration test; not part of `swift test`.
#
#   bash scripts/build-app.sh && bash scripts/ae-roundtrip.sh [image]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Masume.app"
IMAGE="${1:-$ROOT/Resources/AppIcon.png}"
[[ -d "$APP" ]] || { echo "error: build the app first ($APP missing)" >&2; exit 1; }

jxa() { osascript -l JavaScript -e "$1"; }
execute() {
    # $1: a JSON object literal (JavaScript syntax is fine).
    jxa "Application('Masume').execute(JSON.stringify($1))"
}
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

open -a "$APP" "$IMAGE"
sleep 2

echo "==> properties"
DOC=$(jxa 'Application("Masume").activeDocument.id()')
REV=$(jxa 'Application("Masume").activeDocument.revision()')
COLS=$(jxa 'Application("Masume").activeDocument.gridColumns()')
ROWS=$(jxa 'Application("Masume").activeDocument.gridRows()')
echo "document $DOC revision $REV grid ${COLS}x${ROWS}"

echo "==> create arrow B3 -> D6"
OUT=$(execute "{command: 'create_element', documentId: '$DOC', expectedRevision: $REV, actorId: 'shell', actorName: 'Shell',
                reason: 'ae-roundtrip', params: {type: 'arrow', from: 'B3', to: 'D6', color: 'blue'}}")
echo "$OUT" | field "'ok' if d['ok'] else d" | grep -q ok
ARROW=$(echo "$OUT" | field "d['result']['element']['id']")
NEWREV=$(echo "$OUT" | field "d['result']['revision']")
echo "arrow $ARROW at revision $NEWREV"
[[ "$NEWREV" == $((REV + 1)) ]]

echo "==> stale revision is a conflict and changes nothing"
OUT=$(execute "{command: 'delete_elements', documentId: '$DOC', expectedRevision: $REV, params: {ids: ['$ARROW']}}")
[[ "$(echo "$OUT" | field "d['error']['code']")" == "conflict" ]]
[[ "$(jxa 'Application("Masume").activeDocument.revision()')" == "$NEWREV" ]]

echo "==> malformed JSON is the only scripting error"
if jxa "Application('Masume').execute('{nope')" 2>/dev/null; then echo "expected an error" >&2; exit 1; fi

echo "==> base-image crop of B3:D6"
OUT=$(execute "{command: 'view_base_image', documentId: '$DOC', params: {range: 'B3:D6'}}")
CROP=$(echo "$OUT" | field "d['result']['path']")
W=$(echo "$OUT" | field "d['result']['width']")
[[ -f "$CROP" && "$W" -gt 0 ]]
rm -f "$CROP"
echo "crop ${W}px wide, written and removed"

echo "==> undo as the shell, then history"
execute "{command: 'undo', documentId: '$DOC', expectedRevision: $NEWREV, actorId: 'shell', actorName: 'Shell'}" | field "d['result']['summary']"
execute "{command: 'get_history', documentId: '$DOC'}" | field "[e['summary'] for e in d['result']['entries']]"

echo "PASS"

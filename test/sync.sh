#!/bin/bash

# Exercises bing-wallpaper-sync against a recorded API response. No network:
# --dry-run covers URL and state shaping, and the merge/prune cases pre-create
# the image files so the download loop finds nothing to fetch.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$HERE/../bing-wallpaper-sync"
FIXTURE="$HERE/fixtures/hpimagearchive-en-US.json"

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

run() { "$SYNC" --fixture "$FIXTURE" "$@"; }

# Populate a library directory with empty-but-nonzero stand-ins for every image
# the fixture names, so a real (non-dry) run has nothing to download.
seed_images() {
  local dir="$1" res="$2"
  mkdir -p "$dir/images"
  while IFS= read -r date; do
    printf 'x' > "$dir/images/$date-en-US-$res.jpg"
  done < <(jq -r '.images[].startdate' "$FIXTURE")
}

echo "bing-wallpaper-sync"

# --- shaping -----------------------------------------------------------------

out=$(run --dry-run --dir "$WORK/a" --resolution UHD)
is "dry run succeeds"            "$?"                                   "0"
is "reports every fixture day"   "$(jq -r '.count' <<<"$out")"          "8"
is "downloads nothing when dry"  "$(jq -r '.downloaded' <<<"$out")"     "0"
is "flags itself as a dry run"   "$(jq -r '.dryRun' <<<"$out")"         "true"
is "writes no state file"        "$([[ -e $WORK/a/state.json ]] && echo yes || echo no)" "no"

today=$(jq -r '.today.date' <<<"$out")
is "newest entry first" "$today" "$(jq -r '[.images[].startdate] | max' "$FIXTURE")"
is "builds the UHD url" \
  "$(jq -r '.today.url' <<<"$out")" \
  "https://www.bing.com$(jq -r '.images[0].urlbase' "$FIXTURE")_UHD.jpg"
is "names the file by date, market and size" \
  "$(jq -r '.today.file' <<<"$out")" \
  "$WORK/a/images/$today-en-US-UHD.jpg"
is "carries the copyright line" \
  "$(jq -r '.today.copyright' <<<"$out")" \
  "$(jq -r '.images[0].copyright' "$FIXTURE")"
is "every day gets a title" \
  "$(jq -r '.today.title | length > 0' <<<"$out")" "true"

out=$(run --dry-run --dir "$WORK/a" --resolution 1366x768)
is "resolution reaches the url" \
  "$(jq -r '.today.url | endswith("_1366x768.jpg")' <<<"$out")" "true"
is "resolution reaches the filename" \
  "$(jq -r '.today.file | endswith("-1366x768.jpg")' <<<"$out")" "true"

# --- state, merge, prune -----------------------------------------------------

seed_images "$WORK/b" UHD
out=$(run --dir "$WORK/b" --resolution UHD)
is "real run finds the seeded files" "$(jq -r '.downloaded' <<<"$out")" "0"
is "writes state.json"               "$([[ -s $WORK/b/state.json ]] && echo yes || echo no)" "yes"
is "state lists every day"           "$(jq -r '.entries | length' "$WORK/b/state.json")" "8"
is "state records the market"        "$(jq -r '.market' "$WORK/b/state.json")" "en-US"
is "entries are newest first" \
  "$(jq -r '[.entries[].date] == ([.entries[].date] | sort | reverse)' "$WORK/b/state.json")" "true"

# An archived entry whose file was deleted behind our back must leave
# state.json. It has to be a day the fixture no longer carries, otherwise the
# download loop would simply fetch the image again — which is the right thing
# for a day Bing still serves, and not what this case is about.
ghost_date=$(date -d '-20 days' +%Y%m%d)
jq -c --arg d "$ghost_date" --arg f "$WORK/b/images/$ghost_date-en-US-UHD.jpg" \
  '.entries += [{date:$d, title:"Ghost", copyright:"", copyrightLink:"", urlBase:"", market:"en-US", resolution:"UHD", url:"", file:$f}]' \
  "$WORK/b/state.json" > "$WORK/b/state.tmp" && mv "$WORK/b/state.tmp" "$WORK/b/state.json"
is "the ghost entry is in state" \
  "$(jq -r --arg d "$ghost_date" 'any(.entries[]; .date == $d)' "$WORK/b/state.json")" "true"
run --dir "$WORK/b" --resolution UHD >/dev/null
is "drops entries whose file vanished" \
  "$(jq -r --arg d "$ghost_date" 'any(.entries[]; .date == $d)' "$WORK/b/state.json")" "false"
is "the surviving days are untouched" "$(jq -r '.entries | length' "$WORK/b/state.json")" "8"

# A stray file no entry claims must be swept.
printf 'x' > "$WORK/b/images/19990101-en-US-UHD.jpg"
out=$(run --dir "$WORK/b" --resolution UHD)
is "sweeps unclaimed files"    "$(jq -r '.pruned' <<<"$out")" "1"
is "stray file is gone"        "$([[ -e $WORK/b/images/19990101-en-US-UHD.jpg ]] && echo yes || echo no)" "no"

# Retention is by date, not by what the API happens to still serve.
cutoff_days=3
out=$(run --dir "$WORK/b" --resolution UHD --keep "$cutoff_days")
expected=$(jq -r --arg c "$(date -d "-$cutoff_days days" +%Y%m%d)" \
  '[.images[].startdate | select(. >= $c)] | length' "$FIXTURE")
is "--keep bounds the library" "$(jq -r '.entries | length' "$WORK/b/state.json")" "$expected"

# Days older than the API window survive as long as their file does.
old_date=$(date -d '-5 days' +%Y%m%d)
printf 'x' > "$WORK/b/images/$old_date-en-US-UHD.jpg"
jq -c --arg d "$old_date" --arg f "$WORK/b/images/$old_date-en-US-UHD.jpg" \
  '.entries += [{date:$d, title:"Archived", copyright:"", copyrightLink:"", urlBase:"", market:"en-US", resolution:"UHD", url:"", file:$f}]' \
  "$WORK/b/state.json" > "$WORK/b/state.tmp" && mv "$WORK/b/state.tmp" "$WORK/b/state.json"
run --dir "$WORK/b" --resolution UHD --keep 30 >/dev/null
is "keeps archived days the API no longer serves" \
  "$(jq -r --arg d "$old_date" 'any(.entries[]; .date == $d)' "$WORK/b/state.json")" "true"

# --- input validation --------------------------------------------------------

run --dir "$WORK/c" --market nonsense --dry-run >/dev/null 2>&1
is "rejects a malformed market"     "$?" "1"
run --dir "$WORK/c" --resolution 4k --dry-run >/dev/null 2>&1
is "rejects an unknown resolution"  "$?" "1"
run --dir "$WORK/c" --keep 0 --dry-run >/dev/null 2>&1
is "rejects --keep 0"               "$?" "1"
"$SYNC" --fixture "$WORK/nope.json" --dry-run --dir "$WORK/c" >/dev/null 2>&1
is "rejects a missing fixture"      "$?" "1"

printf '{"images":[]}' > "$WORK/empty.json"
"$SYNC" --fixture "$WORK/empty.json" --dry-run --dir "$WORK/c" >/dev/null 2>&1
is "rejects an empty archive"       "$?" "2"

echo
printf '%d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))

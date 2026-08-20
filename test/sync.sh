#!/bin/bash

# Exercises bing-wallpaper-sync against a recorded API response. Offline but
# for one case: --dry-run covers URL and state shaping, the merge/prune cases
# pre-create the image files so the download loop finds nothing to fetch, the
# corrupt-state cases — where there is no usable state to compare against —
# point https_proxy at a closed port so the refetch they provoke fails
# instantly, and the download-validation cases put a stub curl on PATH so they
# choose the exact bytes that come back.
#
# The exception is the robots.txt case, which asks bing.com (the only host this
# plugin ever contacts) for a real 200 that is not an image. With no network it
# fails to fetch instead, which lands on the same assertions.

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

# The naming contract, restated here on purpose: filenames are what Omarchy
# shows as the background's display name, so a test that pins them is pinning
# something a user sees.
slugged_name() {
  jq -r --argjson i "$1" '
    def slug:
      ascii_downcase
      | gsub("[^\\p{L}\\p{N}]+"; "-")
      | gsub("^-+|-+$"; "")
      | .[0:48]
      | until(utf8bytelength <= 120; .[0:-1])
      | gsub("-+$"; "");
    .images[$i]
    | (if (.title // "") != "" then .title else ((.copyright // "") | split(" (©")[0]) end) as $title
    | ($title | slug) as $slug
    | .startdate + (if $slug != "" then "-" + $slug else "" end) + ".jpg"
  ' "$FIXTURE"
}

# Answers with the basename the sync script would give an image whose title is
# $1. A one-image fixture plus --dry-run keeps it offline — the URL is shaped
# but never fetched — so a title can be anything at all without needing a
# matching image on Bing's servers.
name_for() {
  local title="$1" date="${2:-20260818}"
  jq -n --arg t "$title" --arg d "$date" \
    '{images:[{startdate:$d, fullstartdate:($d + "0700"), enddate:$d,
               urlbase:"/th?id=OHR.Test_EN-US0000000000", title:$t,
               copyright:"", copyrightlink:""}]}' > "$WORK/title.json"
  "$SYNC" --fixture "$WORK/title.json" --dry-run --dir "$WORK/n" \
    | jq -r '.today.file | ltrimstr("'"$WORK"'/n/images/")'
}

# Answers with the copyrightLink the sync script would store for a feed value of
# $1. Same one-image, --dry-run trick as name_for, so it stays offline.
link_for() {
  jq -n --arg l "$1" \
    '{images:[{startdate:"20260818", fullstartdate:"202608180700", enddate:"20260818",
               urlbase:"/th?id=OHR.Test_EN-US0000000000", title:"Test",
               copyright:"", copyrightlink:$l}]}' > "$WORK/link.json"
  "$SYNC" --fixture "$WORK/link.json" --dry-run --dir "$WORK/l" \
    | jq -r '.today.copyrightLink'
}

bytes_in() { printf '%s' "$1" | wc -c; }

# The retention filter compares dates as strings, so a value starting below
# "2" sorts under every cutoff and is dropped for a reason that has nothing to
# do with validation. Four of the cases below are invisible end to end because
# of it, so date_ok is also exercised on its own, lifted out of the script so
# the test breaks if the definition is weakened or removed.
DATE_OK_DEF="$(grep -m1 'def date_ok:' "$SYNC")"

date_ok_says() {
  [[ -n $DATE_OK_DEF ]] || { echo "no date_ok in $SYNC"; return; }
  jq -rn --arg d "$1" "$DATE_OK_DEF if (\$d | date_ok) then \"accepted\" else \"refused\" end" \
    2>/dev/null || echo "error"
}

# startdate names the image file, so it decides where a download is written.
# Returns the path the script would use, or the empty string when the entry is
# refused outright.
file_for_date() {
  jq -n --arg d "$1" \
    '{images:[{startdate:$d, fullstartdate:"202608180700", enddate:"20260818",
               urlbase:"/th?id=OHR.Test_EN-US0000000000", title:"Test",
               copyright:"", copyrightlink:""}]}' > "$WORK/date.json"
  # A fresh library each time. Sharing one would let a refused entry fall back
  # to whatever an earlier call left in state.json, and the test would pass on
  # a stale path rather than on the refusal.
  rm -rf "$WORK/d"
  "$SYNC" --fixture "$WORK/date.json" --dry-run --dir "$WORK/d" \
    | jq -r '.today.file // ""'
}

# A stub curl that reports success and writes real JPEG magic wherever -o
# points, so a traversal that gets as far as the write leaves proof behind.
stub_curl_dir() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while (( $# )); do
  [[ $1 == -o ]] && { out="$2"; shift; }
  shift
done
[[ -n $out ]] && printf '\xff\xd8\xff\xe0STUB' > "$out"
STUB
  chmod +x "$dir/curl"
}


# Populate a library directory with empty-but-nonzero stand-ins for every image
# the fixture names, and a state file that claims them, so a real (non-dry) run
# has nothing to download.
seed_images() {
  local dir="$1" res="$2" count i name
  mkdir -p "$dir/images"
  count=$(jq -r '.images | length' "$FIXTURE")
  local entries='[]'
  for (( i = 0; i < count; i++ )); do
    name=$(slugged_name "$i")
    printf 'x' > "$dir/images/$name"
    entries=$(jq -c --arg d "$(jq -r --argjson i "$i" '.images[$i].startdate' "$FIXTURE")" \
      --arg f "$dir/images/$name" --arg r "$res" \
      '. + [{date:$d, title:"seed", copyright:"", copyrightLink:"", urlBase:"", market:"en-US", resolution:$r, url:"", file:$f}]' \
      <<<"$entries")
  done
  jq -n --argjson e "$entries" --arg r "$res" \
    '{version:1, market:"en-US", resolution:$r, keepDays:30, fetchedAt:0, entries:$e}' \
    > "$dir/state.json"
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
is "names the file by date and image title" \
  "$(jq -r '.today.file' <<<"$out")" \
  "$WORK/a/images/$(slugged_name 0)"
is "carries the copyright line" \
  "$(jq -r '.today.copyright' <<<"$out")" \
  "$(jq -r '.images[0].copyright' "$FIXTURE")"
is "every day gets a title" \
  "$(jq -r '.today.title | length > 0' <<<"$out")" "true"

out=$(run --dry-run --dir "$WORK/a" --resolution 1366x768)
is "resolution reaches the url" \
  "$(jq -r '.today.url | endswith("_1366x768.jpg")' <<<"$out")" "true"
is "resolution stays out of the filename" \
  "$(jq -r '.today.file' <<<"$out")" "$WORK/a/images/$(slugged_name 0)"
is "the recorded size is the requested one" \
  "$(jq -r '.today.resolution' <<<"$out")" "1366x768"

# --- naming, beyond ASCII ----------------------------------------------------

# Stripping everything outside [a-z0-9] left a non-Latin market with nothing but
# a date to show, which is exactly what title-based naming was meant to avoid.
# The slug keeps Unicode letters and digits instead.
is "keeps a Japanese title" \
  "$(name_for '富士山の日の出')" "20260818-富士山の日の出.jpg"
is "keeps a Chinese title" \
  "$(name_for '黄山的云海')" "20260818-黄山的云海.jpg"
is "keeps a Korean title" \
  "$(name_for '한라산의 가을')" "20260818-한라산의-가을.jpg"
is "keeps a Cyrillic title" \
  "$(name_for 'Восход над горой')" "20260818-Восход-над-горой.jpg"
is "keeps a Greek title" \
  "$(name_for 'Ηλιοβασίλεμα στη θάλασσα')" "20260818-Ηλιοβασίλεμα-στη-θάλασσα.jpg"
is "keeps both halves of a mixed title" \
  "$(name_for 'sunset 🌅 over 富士山')" "20260818-sunset-over-富士山.jpg"
is "keeps non-ASCII digits" \
  "$(name_for 'Sahara ٢٠٢٦')" "20260818-sahara-٢٠٢٦.jpg"

# ASCII naming is the contract the existing library on disk was written under;
# widening the character class must not rename anything already downloaded.
is "leaves an ASCII title exactly as it was" \
  "$(name_for 'Geometry Of A Star City')" "20260818-geometry-of-a-star-city.jpg"

# A title with no letters or digits at all still has to name a file.
is "falls back to the date for punctuation only" \
  "$(name_for '!!!___###')" "20260818.jpg"
is "falls back to the date for emoji only" \
  "$(name_for '🌅🌅🌅')" "20260818.jpg"

# --- naming is not an injection surface --------------------------------------

# Everything below is a regression guard. The title comes from a remote JSON
# document and becomes a path we write, so the slug is the only thing standing
# between Bing's payload and the filesystem.

traversal=$(name_for '../../../etc/passwd')
is "a traversal title keeps no separator" \
  "$traversal" "20260818-etc-passwd.jpg"
is "no filename ever contains a slash" \
  "$([[ $traversal == */* ]] && echo yes || echo no)" "no"
is "a backslash is not a separator either" \
  "$(name_for '..\\..\\windows\\system32')" "20260818-windows-system32.jpg"

is "a leading dash cannot survive" \
  "$(name_for '-rf --no-preserve-root')" "20260818-rf-no-preserve-root.jpg"
is "shell metacharacters do not survive" \
  "$(name_for '; rm -rf / ;')" "20260818-rm-rf.jpg"
is "command substitution does not survive" \
  "$(name_for '$(whoami)`id`')" "20260818-whoami-id.jpg"
is "quotes do not survive" \
  "$(name_for "it's \"quoted\"")" "20260818-it-s-quoted.jpg"

control=$(name_for "$(printf 'line\none\ttab\rback')")
is "newlines and tabs collapse to dashes" \
  "$control" "20260818-line-one-tab-back.jpg"
is "a filename is always one line" \
  "$(printf '%s' "$control" | wc -l)" "0"

# U+202E and the rest of category Cf are not letters, so \p{L}\p{N} drops them.
# Keeping one would let a title reverse how the name renders and disguise the
# extension — "gpj.exe" reading as "exe.jpg".
bidi=$(name_for "$(printf 'photo\u202egpj.txt')")
is "a bidi override is dropped, not preserved" \
  "$bidi" "20260818-photo-gpj-txt.jpg"
is "no format character reaches the filename" \
  "$(printf '%s' "$bidi" | grep -c $'\u202e')" "0"
is "zero-width characters are dropped too" \
  "$(name_for "$(printf 'a\u200bb\ufeffc\u200dd')")" "20260818-a-b-c-d.jpg"

# .[0:48] slices codepoints, so a CJK slug that fits the old cap is three times
# the bytes. The byte cap is what keeps the basename clear of the 255-byte
# limit — with room to spare for the ".part.$$" name a download writes first.
long_ascii=$(name_for "$(printf 'abcdefghij%.0s' 1 2 3 4 5 6 7 8 9 10)")
is "a long ASCII title still stops at 48 characters" \
  "$long_ascii" "20260818-abcdefghijabcdefghijabcdefghijabcdefghijabcdefgh.jpg"
long_cjk=$(name_for "$(printf '富士山の日の出%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)")
is "a long CJK title is bounded in bytes" \
  "$(bytes_in "$long_cjk")" "133"
is "a long CJK name clears the 255-byte limit" \
  "$([[ $(bytes_in "$long_cjk") -lt 255 ]] && echo yes || echo no)" "yes"
is "a bounded name still ends cleanly" \
  "$([[ $long_cjk == *-.jpg ]] && echo yes || echo no)" "no"

# --- state, merge, prune -----------------------------------------------------

seed_images "$WORK/b" UHD
out=$(run --dir "$WORK/b" --resolution UHD)
is "real run finds the seeded files" "$(jq -r '.downloaded' <<<"$out")" "0"
is "writes state.json"               "$([[ -s $WORK/b/state.json ]] && echo yes || echo no)" "yes"
is "state lists every day"           "$(jq -r '.entries | length' "$WORK/b/state.json")" "8"
is "state records the market"        "$(jq -r '.market' "$WORK/b/state.json")" "en-US"
is "entries are newest first" \
  "$(jq -r '[.entries[].date] == ([.entries[].date] | sort | reverse)' "$WORK/b/state.json")" "true"

# A size change reuses the same path but must still refetch, since the file on
# disk is the wrong image data under the right name.
seed_images "$WORK/d" UHD
out=$(run --dir "$WORK/d" --resolution UHD)
is "a matching size refetches nothing" "$(jq -r '.downloaded' <<<"$out")" "0"
out=$(run --dir "$WORK/d" --resolution 1366x768 --dry-run)
is "a size change is detected as stale" \
  "$(jq -r '.today.resolution' <<<"$out")" "1366x768"

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

# --- corrupt state -----------------------------------------------------------

# A state.json we cannot read must cost at most one re-download, never the
# library itself. The dangerous shapes are the ones jq exits 0 on: an empty
# file prints nothing, and an .entries that is not an array prints a non-array.
# Both used to reach the merge, blow it up, and leave the prune pass deleting
# every image the run had just fetched.
#
# The run below has no usable previous state, so its download loop tries to
# refetch the whole archive; https_proxy aims those requests at a closed port
# to keep the case offline and instant. Failed downloads leave the seeded files
# untouched, which is what makes this a test of the merge rather than of the
# network. Answers "<entries in state> <images on disk> <pruned>".
corrupt_state() {
  local content="$2" dir="$WORK/corrupt-$1" out
  seed_images "$dir" UHD
  printf '%s' "$content" > "$dir/state.json"
  out=$(https_proxy=http://127.0.0.1:1 run --dir "$dir" --resolution UHD 2>/dev/null)
  printf '%s %s %s\n' \
    "$(jq -r '.entries | length' "$dir/state.json" 2>/dev/null)" \
    "$(find "$dir/images" -maxdepth 1 -type f -name '*.jpg' | wc -l)" \
    "$(jq -r '.pruned' <<<"$out" 2>/dev/null)"
}

# The destructive signature was "8 0 8" — eight days re-downloaded, nothing
# left on disk, eight images pruned.
is "an empty state.json keeps the library"   "$(corrupt_state empty '')"                        "8 8 0"
is "a whitespace-only state.json keeps it"   "$(corrupt_state blank '   ')"                     "8 8 0"
is "a string .entries keeps it"              "$(corrupt_state string '{"entries":"wrong"}')"    "8 8 0"
is "an object .entries keeps it"             "$(corrupt_state object '{"entries":{"a":1}}')"    "8 8 0"
is "a number .entries keeps it"              "$(corrupt_state number '{"entries":42}')"         "8 8 0"
is "a null .entries keeps it"                "$(corrupt_state null '{"entries":null}')"         "8 8 0"

# These two were already safe — jq exits non-zero on the first and on the
# second, since .entries cannot be read from an array — and must stay that way.
is "unparseable json keeps it"               "$(corrupt_state garbage 'not json at all')"       "8 8 0"
is "a top-level array keeps it"              "$(corrupt_state array '[]')"                      "8 8 0"

# Losing the stored library is worth a word: the run costs a full re-download,
# and it used to report nothing but "ok". --dry-run keeps this offline.
mkdir -p "$WORK/corrupt-flag"
printf '' > "$WORK/corrupt-flag/state.json"
out=$(run --dry-run --dir "$WORK/corrupt-flag" 2>/dev/null)
is "reports the recovery"        "$(jq -r '.recoveredState' <<<"$out")" "true"
is "still resolves every day"    "$(jq -r '.count' <<<"$out")"          "8"
err=$(run --dry-run --dir "$WORK/corrupt-flag" 2>&1 >/dev/null)
is "the recovery names the file" \
  "$([[ $err == *"$WORK/corrupt-flag/state.json"* ]] && echo yes || echo no)" "yes"

out=$(run --dry-run --dir "$WORK/b")
is "a readable state is not flagged" "$(jq -r '.recoveredState' <<<"$out")" "false"

# --- what counts as an image -------------------------------------------------

# The download used to promote anything non-empty. A 200 carrying an HTML error
# page, a text file, or a transfer cut short before any image data is not a
# JPEG, and every one of them used to be saved under a .jpg name, recorded in
# state.json, and handed to the background setter when autoApply is on.
#
# The stub below is a curl placed earlier on PATH than the real one, so these
# cases pick the exact bytes that come back and reach no network at all. It
# also appends every URL it was asked for to $STUB_LOG, which is what lets the
# origin cases further down assert that a rejected entry was never fetched.
STUB_DIR="$WORK/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/curl" <<'STUB'
#!/bin/bash
out=""; url=""
while (( $# > 0 )); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -A|-H|--max-time|--retry|--retry-delay|--proto|--proto-redir|--max-redirs) shift 2 ;;
    -*) shift ;;
    *)  url="$1"; shift ;;
  esac
done
[[ -n ${STUB_LOG:-} ]] && printf '%s\n' "$url" >> "$STUB_LOG"
[[ -n $out ]] || exit 0

body="${STUB_BODY:-jpeg}"
# "fallback" refuses the requested size the way Bing does for images it no
# longer publishes at UHD, and answers the next size down with a real JPEG.
if [[ $body == fallback ]]; then
  if [[ $url == *_UHD.jpg ]]; then body=html; else body=jpeg; fi
fi

case "$body" in
  jpeg)      { printf '\xff\xd8\xff\xe0\x00\x10JFIF\x00'; head -c 256 /dev/zero; printf '\xff\xd9'; } > "$out" ;;
  html)      printf '<!doctype html><title>Browser Not Supported</title>' > "$out" ;;
  text)      printf 'User-agent: *\nDisallow: /\n' > "$out" ;;
  empty)     : > "$out" ;;
  truncated) printf '\xff\xd8' > "$out" ;;
  *)         exit 22 ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/curl"

# Runs a real (non-dry) sync over a one-day fixture whose urlbase is $2, with
# every download answered by the stub in mode $1. Answers
# "<downloaded> <failed> <entries> <jpgs on disk> <urls requested>".
stubbed() {
  local body="$1" urlbase="$2" tag="$3"
  local dir="$WORK/stub-$tag" fixture="$WORK/stub-$tag.json" log="$WORK/stub-$tag.log" out
  jq -n --arg b "$urlbase" \
    '{images:[{startdate:"20260819", fullstartdate:"202608190700", enddate:"20260819",
               urlbase:$b, title:"Probe", copyright:"", copyrightlink:""}]}' > "$fixture"
  : > "$log"
  out=$(env PATH="$STUB_DIR:$PATH" STUB_BODY="$body" STUB_LOG="$log" \
    "$SYNC" --fixture "$fixture" --dir "$dir" --resolution UHD 2>/dev/null)
  printf '%s %s %s %s %s\n' \
    "$(jq -r '.downloaded' <<<"$out")" \
    "$(jq -r '.failed' <<<"$out")" \
    "$(jq -r '.count' <<<"$out")" \
    "$(find "$dir/images" -maxdepth 1 -type f -name '*.jpg' 2>/dev/null | wc -l)" \
    "$(grep -c . "$log")"
}

GOOD='/th?id=OHR.Probe_EN-US0000000000'

# A whole JPEG is the control: it has to land, or the cases below prove nothing.
is "a real JPEG is accepted"        "$(stubbed jpeg "$GOOD" jpeg)"       "1 0 1 1 1"

# The requested size failing must not weaken the check. Four fallback sizes
# follow UHD, so a refused image costs five requests and still counts as one
# failure.
is "an HTML page is not an image"   "$(stubbed html "$GOOD" html)"       "0 1 0 0 5"
is "a text file is not an image"    "$(stubbed text "$GOOD" text)"       "0 1 0 0 5"
is "an empty 200 is not an image"   "$(stubbed empty "$GOOD" empty)"     "0 1 0 0 5"

# Two bytes is the SOI marker and nothing after it: present, non-empty, and cut
# short before the first segment ever starts.
is "a truncated JPEG is refused"    "$(stubbed truncated "$GOOD" trunc)" "0 1 0 0 5"

is "nothing is left half-written" \
  "$(find "$WORK" -name '*.part.*' 2>/dev/null | wc -l)" "0"

# The fallback ladder promotes files too, so it has to validate them too. Here
# UHD answers with an HTML page and 1920x1200 with a real JPEG: the image lands
# and state records the size that actually arrived.
is "the fallback path still downloads" "$(stubbed fallback "$GOOD" fb)" "1 0 1 1 2"
is "the fallback records the size it got" \
  "$(jq -r '.entries[0].resolution' "$WORK/stub-fb/state.json")" "1920x1200"
is "the fallback url is the one that worked" \
  "$(tail -n 1 "$WORK/stub-fb.log")" \
  "https://www.bing.com${GOOD}_1920x1200.jpg"

# The reproducer that opened this, against bing.com itself and no other host.
# "/robots.txt?pad=" builds a URL Bing answers 200 with a text file; it used to
# be saved as 20260819-not-an-image.jpg and recorded as a library entry. This
# is the one case in the suite that touches the network, and with no network it
# simply fails to fetch, which lands on exactly these same assertions.
jq -n '{images:[{startdate:"20260819", fullstartdate:"202608190700", enddate:"20260819",
                 urlbase:"/robots.txt?pad=", title:"Not An Image",
                 copyright:"", copyrightlink:""}]}' > "$WORK/robots.json"
out=$("$SYNC" --fixture "$WORK/robots.json" --dir "$WORK/robots" --resolution UHD 2>/dev/null)
is "bing's own robots.txt is refused as an image" \
  "$(jq -r '.downloaded' <<<"$out")" "0"
is "the refusal counts as a failure" \
  "$(jq -r '.failed' <<<"$out")" "1"
is "no file is promoted" \
  "$(find "$WORK/robots/images" -maxdepth 1 -type f 2>/dev/null | wc -l)" "0"
is "no entry reaches state.json" \
  "$(jq -r '.entries | length' "$WORK/robots/state.json")" "0"

# --- the feed does not get to pick the origin --------------------------------

# The download URL is "https://www.bing.com" + urlbase, and concatenation alone
# does not pin a host: a leading "@" turns the pinned name into userinfo and
# the request lands on whatever follows. urlbase now has to look like a path,
# so these are dropped during normalization and never reach curl. The stub log
# is what proves the second half of that.
escape() { stubbed jpeg "$1" "$2"; }

is "a leading @ makes it userinfo, so it is dropped" \
  "$(escape '@bing-wallpaper-test.example/evil' at)"       "0 0 0 0 0"
is "a protocol-relative // is dropped" \
  "$(escape '//bing-wallpaper-test.example/evil' slashes)" "0 0 0 0 0"
is "an absolute https url is dropped" \
  "$(escape 'https://bing-wallpaper-test.example/evil' abs)" "0 0 0 0 0"
is "a backslash is dropped" \
  "$(escape '\bing-wallpaper-test.example\evil' backslash)" "0 0 0 0 0"
is "a control character is dropped" \
  "$(escape "$(printf '/th?id=x\nHost: elsewhere')" control)" "0 0 0 0 0"
is "a urlbase with no leading slash is dropped" \
  "$(escape 'th?id=OHR.Probe_EN-US0000000000' noslash)"    "0 0 0 0 0"
is "a space is dropped" \
  "$(escape '/th?id=a b' space)"                           "0 0 0 0 0"
is "a colon is dropped" \
  "$(escape '/th:id=a' colon)"                             "0 0 0 0 0"

# REGRESSION. An allowlist is only worth having if it still passes what Bing
# actually sends, so the recorded response has to come through untouched: every
# day survives normalization, every day downloads, and the names are the ones
# already on disk in existing libraries. The stub supplies the image bytes, so
# this stays offline and deterministic.
: > "$WORK/real.log"
out=$(env PATH="$STUB_DIR:$PATH" STUB_BODY=jpeg STUB_LOG="$WORK/real.log" \
  "$SYNC" --fixture "$FIXTURE" --dir "$WORK/real" --resolution UHD)
is "every recorded urlbase survives the allowlist" "$(jq -r '.count' <<<"$out")"      "8"
is "every day still downloads"                     "$(jq -r '.downloaded' <<<"$out")" "8"
is "nothing is dropped as a failure"               "$(jq -r '.failed' <<<"$out")"     "0"
is "the filenames are the ones they always were" \
  "$(jq -r '.today.file' <<<"$out")" "$WORK/real/images/$(slugged_name 0)"
is "the whole library reaches disk" \
  "$(find "$WORK/real/images" -maxdepth 1 -type f -name '*.jpg' | wc -l)" "8"
is "each day is asked for exactly once" "$(grep -c . "$WORK/real.log")" "8"
is "the url is the pinned origin plus the feed's path" \
  "$(head -n 1 "$WORK/real.log")" \
  "https://www.bing.com$(jq -r '.images[0].urlbase' "$FIXTURE")_UHD.jpg"
is "every url stays on www.bing.com" \
  "$(grep -cv '^https://www\.bing\.com/' "$WORK/real.log")" "0"

# A second run over the same library downloads nothing again.
out=$(env PATH="$STUB_DIR:$PATH" STUB_BODY=jpeg \
  "$SYNC" --fixture "$FIXTURE" --dir "$WORK/real" --resolution UHD)
is "a second run is idempotent" "$(jq -r '.downloaded' <<<"$out")" "0"
is "and keeps every day"        "$(jq -r '.count' <<<"$out")"      "8"

# --- input validation --------------------------------------------------------

run --dir "$WORK/c" --market nonsense --dry-run >/dev/null 2>&1
is "rejects a malformed market"     "$?" "1"
run --dir "$WORK/c" --resolution 4k --dry-run >/dev/null 2>&1
is "rejects an unknown resolution"  "$?" "1"
run --dir "$WORK/c" --keep 0 --dry-run >/dev/null 2>&1
is "rejects --keep 0"               "$?" "1"
run --dir "$WORK/c" --count 16 --dry-run >/dev/null 2>&1
is "rejects a count past the archive" "$?" "1"
run --dir "$WORK/c" --count 0 --dry-run >/dev/null 2>&1
is "rejects --count 0"              "$?" "1"

# --count trims after paging, so asking for fewer days than a page holds does
# not get widened back out to the page size.
out=$(run --dry-run --dir "$WORK/c" --count 3)
is "--count bounds the request"     "$(jq -r '.count' <<<"$out")" "3"
is "--count keeps the newest days" \
  "$(jq -r '.today.date' <<<"$out")" "$(jq -r '[.images[].startdate] | max' "$FIXTURE")"
"$SYNC" --fixture "$WORK/nope.json" --dry-run --dir "$WORK/c" >/dev/null 2>&1
is "rejects a missing fixture"      "$?" "1"

printf '{"images":[]}' > "$WORK/empty.json"
"$SYNC" --fixture "$WORK/empty.json" --dry-run --dir "$WORK/c" >/dev/null 2>&1
is "rejects an empty archive"       "$?" "2"

# --- a flag with no value ----------------------------------------------------

# A value-taking flag left last on the command line used to hang the script for
# good: `shift 2` fails with one argument remaining and, since the script runs
# without -e, nothing noticed and the loop re-read the same argument forever.
#
# Every invocation below is wrapped in timeout, and a timeout is reported as the
# failure it is. A suite that hangs never reports at all, which is worse than
# one that fails.
trailing_flag() {
  local flag="$1" err rc
  err=$(timeout 5 "$SYNC" --fixture "$FIXTURE" --dir "$WORK/c" "$flag" 2>&1 >/dev/null)
  rc=$?
  if (( rc == 124 )); then
    printf 'hung — the argument loop is spinning'
  elif (( rc == 0 )); then
    printf 'exited 0'
  elif [[ $err != *"$flag requires a value"* ]]; then
    printf 'exit %d with stderr: %s' "$rc" "$err"
  else
    printf 'refused'
  fi
}

is "--market alone is refused"      "$(trailing_flag --market)"     "refused"
is "--resolution alone is refused"  "$(trailing_flag --resolution)" "refused"
is "--keep alone is refused"        "$(trailing_flag --keep)"       "refused"
is "--dir alone is refused"         "$(trailing_flag --dir)"        "refused"
is "--count alone is refused"       "$(trailing_flag --count)"      "refused"
is "--fixture alone is refused"     "$(trailing_flag --fixture)"    "refused"

# The rest of the argument loop, pinned so the arity check does not disturb it.
err=$(timeout 5 "$SYNC" --fixture "$FIXTURE" --dir "$WORK/c" --market "" --dry-run 2>&1 >/dev/null)
is "an explicitly empty value is still a value" \
  "$([[ $err == *"invalid market:"* ]] && echo yes || echo no)" "yes"
err=$(timeout 5 "$SYNC" --fixture "$FIXTURE" --dir "$WORK/c" --nonsense --dry-run 2>&1 >/dev/null)
is "an unknown flag is still named" \
  "$([[ $err == *"unknown option: --nonsense"* ]] && echo yes || echo no)" "yes"
timeout 5 "$SYNC" --help >/dev/null 2>&1
is "--help exits 0"                 "$?" "0"
timeout 5 "$SYNC" --dry-run --dir "$WORK/c" -h >/dev/null 2>&1
is "-h still works after other flags" "$?" "0"

# --- credit link -------------------------------------------------------------

# copyrightlink is feed data and the panel opens it. It used to be stored
# verbatim and concatenated into a bash -lc command line, so a crafted value ran
# commands on click. The panel no longer uses a shell, and the link is narrowed
# to a plain http(s) URL here too, so a dangerous value never reaches disk.
REAL_LINK="https://www.bing.com/search?q=Palmanova+Italy&form=hpcapt&filters=HpDate%3a%2220260818_0700%22"
is "a real credit link is stored"    "$(link_for "$REAL_LINK")" "$REAL_LINK"
is "command substitution is dropped" "$(link_for 'https://x.test/$(id)')" ""
is "backticks are dropped"           "$(link_for 'https://x.test/`id`')" ""
is "a quoted payload is dropped"     "$(link_for 'https://x.test/a";rm -rf /;"')" ""
is "the javascript scheme is dropped" "$(link_for 'javascript:alert(1)')" ""
is "the file scheme is dropped"      "$(link_for 'file:///etc/passwd')" ""
is "a spaced payload is dropped"     "$(link_for 'https://x.test/a rm -rf /')" ""
is "an empty link stays empty"       "$(link_for '')" ""


# --- where a download is allowed to land -------------------------------------

# startdate is feed data and it is what names the file. A value carrying a
# slash and a .. walked the write out of the image directory and over whatever
# file it reached; the retention filter then dropped the entry, so the
# overwrite left nothing behind in state.json to notice. Bing sends YYYYMMDD.
is "date_ok accepts a real date"     "$(date_ok_says 20260818)" "accepted"
is "date_ok refuses traversal"       "$(date_ok_says '../../../etc/wallpaper')" "refused"
is "date_ok refuses an inner slash"  "$(date_ok_says '20260818/../../evil')" "refused"
is "date_ok refuses an absolute path" "$(date_ok_says '/etc/wallpaper')" "refused"
is "date_ok refuses a short date"    "$(date_ok_says 2026081)" "refused"
is "date_ok refuses a long date"     "$(date_ok_says 202608180)" "refused"
is "date_ok refuses a non-digit"     "$(date_ok_says 2026081x)" "refused"
is "date_ok refuses padding"         "$(date_ok_says ' 20260818 ')" "refused"
is "date_ok refuses a trailing newline" "$(date_ok_says '20260818
')" "refused"
is "date_ok refuses emptiness"       "$(date_ok_says '')" "refused"

is "a real date names a file"        "$(basename "$(file_for_date 20260818)")" "20260818-test.jpg"
is "a traversing date is refused"    "$(file_for_date '../../../etc/wallpaper')" ""
is "a date with a slash is refused"  "$(file_for_date '20260818/../../evil')" ""
is "an absolute date is refused"     "$(file_for_date '/etc/wallpaper')" ""
is "a short date is refused"         "$(file_for_date '2026081')" ""
is "a non-numeric date is refused"   "$(file_for_date '2026081x')" ""
is "a padded date is refused"        "$(file_for_date ' 20260818 ')" ""
is "an empty date is refused"        "$(file_for_date '')" ""

# The end-to-end version of the same thing: a real write, with a file outside
# the library standing in for a user's wallpaper.
TRAV="$WORK/traversal"
mkdir -p "$TRAV/lib/images" "$TRAV/victim"
printf 'ORIGINAL USER FILE\n' > "$TRAV/victim/wall.jpg"
stub_curl_dir "$TRAV/bin"
jq -n '{images:[{startdate:"../../victim/wall", fullstartdate:"202608180700",
                 enddate:"20260818", urlbase:"/th?id=OHR.Test_EN-US0000000000",
                 title:"©©©", copyright:"(© x)", copyrightlink:""}]}' > "$TRAV/f.json"
PATH="$TRAV/bin:$PATH" "$SYNC" --fixture "$TRAV/f.json" --dir "$TRAV/lib" \
  > "$TRAV/out.json" 2>/dev/null
is "the file outside the library is untouched" \
   "$(cat "$TRAV/victim/wall.jpg")" "ORIGINAL USER FILE"
is "nothing was downloaded for it" \
   "$(jq -r '.downloaded' < "$TRAV/out.json")" "0"

# --- staying on bing.com -----------------------------------------------------

# --proto-redir pins the scheme a redirect may use, not the host, so the old
# `curl -fsSL` would follow an https redirect to any host the feed's origin
# named. Both Bing endpoints answer 200 with no redirect, so the fetcher no
# longer follows one it cannot verify.
is "no -L is passed to curl" \
   "$(grep -c -- '-fsSL' "$SYNC")" "0"
is "curl is capped at zero redirects" \
   "$(grep -c -- "--max-redirs 0" "$SYNC")" "1"
is "the origin allowlist is a single host" \
   "$(grep -c '^BING_ORIGIN="https://www.bing.com"$' "$SYNC")" "1"

# The redirect decision itself, exercised without a network: a stub curl that
# reports a next hop through -w, first on the origin and then off it.
redirect_to() {
  local location="$1" dir="$WORK/redir"
  rm -rf "$dir"; mkdir -p "$dir/bin"
  printf '%s' "$location" > "$dir/location"
  # Answers every call, not only the first: a failed download is retried at
  # each fallback resolution, so a stub that redirected once would let the
  # second attempt through and hide the refusal. The hop is reported until the
  # caller actually asks for the target, which is what ends a followed chain.
  cat > "$dir/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""
while (( $# )); do
  [[ $1 == -o ]] && { out="$2"; shift; }
  url="$1"
  shift
done
n=$(( $(cat "$STUB_CALLS" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$STUB_CALLS"
# Distinct bytes per call, so the test can tell which hop actually produced
# the file. Identical bytes would let "followed" pass even if bing_get
# ignored the Location and kept the first response.
[[ -n $out ]] && printf '\xff\xd8\xff\xe0HOP%s' "$n" > "$out"
location=$(cat "$STUB_LOCATION")
[[ $url == "$location" ]] || printf '%s' "$location"
STUB
  chmod +x "$dir/bin/curl"
  jq -n '{images:[{startdate:"20260818", fullstartdate:"202608180700",
                   enddate:"20260818", urlbase:"/th?id=OHR.Test_EN-US0000000000",
                   title:"Test", copyright:"", copyrightlink:""}]}' > "$dir/f.json"
  rm -f "$dir/calls"
  STUB_CALLS="$dir/calls" STUB_LOCATION="$dir/location" PATH="$dir/bin:$PATH" \
    "$SYNC" --fixture "$dir/f.json" --dir "$dir/lib" 2>"$dir/err" | jq -r '.downloaded'
}

# What the kept file actually contains, which is what says whether the hop was
# followed or the first response was kept.
redirect_body() {
  cat "$WORK/redir/lib/images/"*.jpg 2>/dev/null | grep -ao 'HOP[0-9]*' | head -1
}

is "a redirect that stays on bing is followed" \
   "$(redirect_to 'https://www.bing.com/th?id=OHR.Test_UHD.jpg')" "1"
is "the kept file came from the second hop" \
   "$(redirect_body)" "HOP2"
is "a redirect to another host is refused" \
   "$(redirect_to 'https://evil.test/x.jpg')" "0"
is "a look-alike host is refused" \
   "$(redirect_to 'https://www.bing.com.evil.test/x.jpg')" "0"
# Once per attempt, and the script tries each fallback resolution, so the count
# is not fixed. That it is reported at all is the point.
is "the refusal is reported" \
   "$(redirect_to 'https://evil.test/x.jpg' >/dev/null
      n=$(grep -c 'refusing a redirect' "$WORK/redir/err"); echo $(( n > 0 )))" "1"

is "a userinfo host is refused" \
   "$(redirect_to 'https://www.bing.com@evil.test/x.jpg')" "0"
is "a relative hop resolves back onto bing" \
   "$(redirect_to 'https://www.bing.com/th/redirected.jpg')" "1"

# An endless chain has to stop, and say which URL it gave up on. The stub keeps
# naming a hop the caller has not asked for yet, so nothing ever resolves.
CHAIN="$WORK/chain"; rm -rf "$CHAIN"; mkdir -p "$CHAIN/bin"
cat > "$CHAIN/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while (( $# )); do
  [[ $1 == -o ]] && { out="$2"; shift; }
  shift
done
n=$(( $(cat "$STUB_CALLS" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$STUB_CALLS"
[[ -n $out ]] && printf '\xff\xd8\xff\xe0LOOP' > "$out"
printf 'https://www.bing.com/hop%s' "$n"
STUB
chmod +x "$CHAIN/bin/curl"
jq -n '{images:[{startdate:"20260818", fullstartdate:"202608180700",
                 enddate:"20260818", urlbase:"/th?id=OHR.Test_EN-US0000000000",
                 title:"Test", copyright:"", copyrightlink:""}]}' > "$CHAIN/f.json"
STUB_CALLS="$CHAIN/calls" PATH="$CHAIN/bin:$PATH" \
  "$SYNC" --fixture "$CHAIN/f.json" --dir "$CHAIN/lib" >/dev/null 2>"$CHAIN/err"
is "an endless chain gives up" \
   "$(grep -c 'too many redirects' "$CHAIN/err" | head -1 | awk '{print ($1 > 0)}')" "1"
is "it names the url it gave up on, not a curl flag" \
   "$(grep -m1 'too many redirects' "$CHAIN/err" | grep -c 'https://www.bing.com')" "1"
is "nothing was kept from the chain" \
   "$(ls "$CHAIN/lib/images" 2>/dev/null | wc -l)" "0"

# --- the containment check underneath date_ok --------------------------------

# date_ok drops a traversing entry before the download loop ever sees it, which
# means the second check in that loop has no way to fire through the front
# door. Run the script with date_ok disabled to reach it, so the belt is tested
# and not merely present.
MUT="$WORK/mutant"; mkdir -p "$MUT/lib/images" "$MUT/victim" "$MUT/bin"
sed 's/def date_ok: test("\\\\A\[0-9\]{8}\\\\z");/def date_ok: true;/' "$SYNC" > "$MUT/sync"
chmod +x "$MUT/sync"
is "the mutant really has date_ok disabled" \
   "$(grep -c 'def date_ok: true;' "$MUT/sync")" "1"
printf 'ORIGINAL USER FILE\n' > "$MUT/victim/wall.jpg"
stub_curl_dir "$MUT/bin"
jq -n '{images:[{startdate:"../../victim/wall", fullstartdate:"202608180700",
                 enddate:"20260818", urlbase:"/th?id=OHR.Test_EN-US0000000000",
                 title:"©©©", copyright:"(© x)", copyrightlink:""}]}' > "$MUT/f.json"
PATH="$MUT/bin:$PATH" "$MUT/sync" --fixture "$MUT/f.json" --dir "$MUT/lib" \
  > "$MUT/out.json" 2>"$MUT/err"
is "the write outside the library is refused" \
   "$(grep -c 'refusing to write outside' "$MUT/err" | awk '{print ($1 > 0)}')" "1"
is "the user file survives the second layer alone" \
   "$(cat "$MUT/victim/wall.jpg")" "ORIGINAL USER FILE"
is "the run reports the failure" \
   "$(jq -r '.ok' < "$MUT/out.json")" "false"

# The same thing again with a date that survives the retention filter and a
# target that already exists, which is the only shape where "was the refused
# entry dropped from the result" is observable at all: the first case is
# recorded as absent whether or not the code drops it, because its date sorts
# below every cutoff and its file was never created.
#
# images/20260818/../../victim/wall.jpg resolves to lib/victim/wall.jpg, so the
# 20260818 directory has to exist for the path to resolve.
MUT2="$WORK/mutant2"; mkdir -p "$MUT2/lib/images/20260818" "$MUT2/lib/victim" "$MUT2/bin"
cp "$MUT/sync" "$MUT2/sync"
printf 'ORIGINAL USER FILE\n' > "$MUT2/lib/victim/wall.jpg"
stub_curl_dir "$MUT2/bin"
jq -n '{images:[{startdate:"20260818/../../victim/wall", fullstartdate:"202608180700",
                 enddate:"20260818", urlbase:"/th?id=OHR.Test_EN-US0000000000",
                 title:"©©©", copyright:"(© x)", copyrightlink:""}]}' > "$MUT2/f.json"
PATH="$MUT2/bin:$PATH" "$MUT2/sync" --fixture "$MUT2/f.json" --dir "$MUT2/lib" \
  > "$MUT2/out.json" 2>"$MUT2/err"
is "the existing file outside the library survives" \
   "$(cat "$MUT2/lib/victim/wall.jpg")" "ORIGINAL USER FILE"
is "a refused entry never reaches state.json" \
   "$(jq -r '.count' < "$MUT2/out.json")" "0"
is "state.json holds no out-of-tree path" \
   "$(jq -r '[.entries[].file | select(contains(".."))] | length' \
      < "$MUT2/lib/state.json" 2>/dev/null || echo 0)" "0"

# --- where a download is staged ----------------------------------------------

# curl -o writes through a symlink already sitting at the path, so the staging
# name must not be one an attacker can predict from the target. mktemp makes it
# unguessable; "$target.part.$$" did not.
STAGE="$WORK/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE/lib/images" "$STAGE/bin"
cat > "$STAGE/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while (( $# )); do
  [[ $1 == -o ]] && { out="$2"; shift; }
  shift
done
[[ -n $out ]] && { basename "$out" >> "$STUB_LOG"; printf '\xff\xd8\xff\xe0STUB' > "$out"; }
STUB
chmod +x "$STAGE/bin/curl"
jq -n '{images:[{startdate:"20260818", fullstartdate:"202608180700",
                 enddate:"20260818", urlbase:"/th?id=OHR.Test_EN-US0000000000",
                 title:"Test", copyright:"", copyrightlink:""}]}' > "$STAGE/f.json"
STUB_LOG="$STAGE/log" PATH="$STAGE/bin:$PATH" \
  "$SYNC" --fixture "$STAGE/f.json" --dir "$STAGE/lib" >/dev/null 2>&1
is "the staging name is not derived from the target" \
   "$(grep -c 'test' "$STAGE/log")" "0"
is "the staging name comes from mktemp" \
   "$(grep -c '^\.part\.' "$STAGE/log")" "1"
is "no staging file is left behind" \
   "$(ls -a "$STAGE/lib/images" | grep -c '^\.part\.')" "0"
is "the image still lands under its real name" \
   "$(ls "$STAGE/lib/images")" "20260818-test.jpg"

# --- a malformed entry does not take the day down ----------------------------

# startdate is typed before it is used to build a filename. A JSON number there
# used to fail the concatenation, and that one error aborted the parse for
# every other day in the same response.
jq -n '{images:[{startdate:20260818, urlbase:"/th?id=OHR.A", title:"Numeric",
                 copyright:"", copyrightlink:""},
                {startdate:"20260817", fullstartdate:"202608170700",
                 enddate:"20260818", urlbase:"/th?id=OHR.B", title:"Good day",
                 copyright:"", copyrightlink:""}]}' > "$WORK/mixed.json"
rm -rf "$WORK/mixed"
MIXED=$("$SYNC" --fixture "$WORK/mixed.json" --dry-run --dir "$WORK/mixed")
is "a numeric startdate does not abort the parse" "$(jq -r '.ok' <<<"$MIXED")" "true"
is "the well-formed day survives it" "$(jq -r '.today.title' <<<"$MIXED")" "Good day"
is "the malformed day is dropped" "$(jq -r '.count' <<<"$MIXED")" "1"

echo
printf '%d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))

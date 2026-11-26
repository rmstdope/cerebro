#!/usr/bin/env bash
#
# scripts/ux-sheet: a text spec becomes one drawing page in the house frame (cb-buko). What the page
# DOES in a browser (tabs, keys, the faded edge) is tests/ux-sheet-render; this suite pins what the
# generator writes, prints and refuses.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

sheet="$repo_root/scripts/ux-sheet"
cd "$work_dir"

# run <args...>: sets rc, out (stdout) and err (stderr).
run() {
  rc=0
  "$sheet" "$@" >"$work_dir/out" 2>"$work_dir/err" || rc=$?
  out="$(cat "$work_dir/out")"
  err="$(cat "$work_dir/err")"
}

has() { grep -qF -- "$2" "$1" || fail "$3: wanted '$2' in $1, got: $(cat "$1")"; }
lacks() { if grep -qF -- "$2" "$1"; then fail "$3: did not want '$2' in $1"; fi; }
count_of() { grep -oF -- "$2" "$1" | wc -l | tr -d ' '; }

cat >options.sheet <<'SPEC'
work: Where the fleet's time went
heading: Which layout do we build on?

<style>.shared-product{color:red}</style>
=== option: tiles & <time>
cost: Every role is one tile; its size is its share of the time.
recommended: a treemap is the usual way to show parts of a whole.

<div class="a-body">the drawing of A &amp; more</div>

=== option: bars, longest first
cost: Easier to compare two roles.
<div class="b-body">the drawing of B</div>
SPEC

# --- an options page ---------------------------------------------------------------------------

run options.sheet
[[ $rc -eq 0 ]] || fail "options: exit $rc: $err"
page=options.html
has "$page" "<title>Which layout do we build on? · Where the fleet&#39;s time went</title>" "options: title"
has "$page" '<div class="ux-work">Where the fleet&#39;s time went</div>' "options: the work line"
has "$page" '<h1 class="ux-heading">Which layout do we build on?</h1>' "options: the heading"
has "$page" 'data-ux-tab="A"' "options: tab A"
has "$page" 'data-ux-tab="B"' "options: tab B"
has "$page" '>A — tiles &amp; &lt;time&gt;<span class="ux-tag ux-rec">Recommended</span></button>' "options: the recommended tab"
has "$page" '>B — bars, longest first</button>' "options: the other tab"
has "$page" '<h2 class="ux-name">A — tiles &amp; &lt;time&gt;<span class="ux-tag ux-rec">Recommended</span></h2>' "options: the recommended heading"
has "$page" '<p class="ux-cost">Every role is one tile; its size is its share of the time.</p>' "options: the cost line"
has "$page" '<p class="ux-why">Recommended: a treemap is the usual way to show parts of a whole.</p>' "options: the reason line"
[[ "$(count_of "$page" 'class="ux-why"')" -eq 1 ]] || fail "options: only the recommended option has a reason"
has "$page" '<div class="a-body">the drawing of A &amp; more</div>' "options: bodies are raw"
[[ "$(count_of "$page" '.shared-product{color:red}')" -eq 1 ]] || fail "options: shared markup appears once"
has "$page" '<section class="ux-panel" role="tabpanel" id="ux-panel-A" aria-labelledby="ux-tab-A">' "options: A shows"
has "$page" '<section class="ux-panel" role="tabpanel" id="ux-panel-B" aria-labelledby="ux-tab-B" hidden>' "options: B is hidden"
lacks "$page" "ux-agreed\">" "options: nothing is agreed"
lacks "$page" "@@" "options: no marker left"
[[ "$out" == "Which layout do we build on?
  On the computer: file://$work_dir/options.html" ]] || fail "options: stdout, got: $out"
pass "an options spec becomes a tabbed page opening on A, and prints its name and computer line"

printf 'work: W\nheading: H\n=== option: one\ncost: c\nrecommended: Recommended: said once\nx\n=== option: two\ncost: c\ny\n' >once.sheet
run once.sheet
has once.html '<p class="ux-why">Recommended: said once</p>' "reason: the prefix is not doubled"
lacks once.html 'Recommended: Recommended:' "reason: the prefix is not doubled"
printf 'work: W\r\nheading: H\r\n=== option: one\r\ncost: c\r\nrecommended: r\r\nx\r\n=== option: two\r\ncost: c\r\ny' >crlf.sheet
run crlf.sheet
[[ $rc -eq 0 ]] || fail "crlf: exit $rc: $err"
lacks crlf.html $'\r' "crlf: carriage returns are dropped"
has crlf.html "y" "crlf: a last line with no newline is kept"
pass "a reason already prefixed, CRLF and a missing final newline are all taken as meant"

# --- out, the file URL -------------------------------------------------------------------------

mkdir -p "a dir"
run options.sheet --out "a dir/kept #1.html"
[[ $rc -eq 0 && -f "a dir/kept #1.html" ]] || fail "out: exit $rc: $err"
grep -qF "  On the computer: file://$work_dir/a%20dir/kept%20%231.html" "$work_dir/out" \
  || fail "out: the computer line is percent-encoded, got: $out"
printf 'work: W\nheading: H\n\n<p>x</p>\n' >"å.sheet"
run "å.sheet"
grep -qF "/%C3%A5.html" "$work_dir/out" || fail "out: bytes outside ASCII are encoded, got: $out"
pass "--out writes there, and the computer line is a percent-encoded file URL"

# --- the kept copy -----------------------------------------------------------------------------

run options.sheet --agreed B --out kept.html
[[ $rc -eq 0 ]] || fail "agreed: exit $rc: $err"
has kept.html '>B — bars, longest first<span class="ux-tag ux-agreed">Agreed</span></button>' "agreed: the tab"
has kept.html '<h2 class="ux-name">B — bars, longest first<span class="ux-tag ux-agreed">Agreed</span></h2>' "agreed: the heading"
has kept.html 'aria-labelledby="ux-tab-A" hidden>' "agreed: A is hidden"
has kept.html 'aria-labelledby="ux-tab-B">' "agreed: B shows"
has kept.html 'id="ux-tab-B" aria-controls="ux-panel-B" aria-selected="true"' "agreed: B is selected"
has kept.html 'class="ux-tag ux-rec">Recommended' "agreed: the recommendation stays"
run options.sheet --agreed A --out kept-a.html
has kept-a.html '<span class="ux-tag ux-rec">Recommended</span><span class="ux-tag ux-agreed">Agreed</span></button>' \
  "agreed: both tags on a recommended choice"
pass "--agreed tags the chosen option and opens the page on it"

# --- states and tabless pages ------------------------------------------------------------------

cat >states.sheet <<'SPEC'
work: Where the fleet's time went
heading: The states — tiles sized by time

=== state: Normal
<p>normal</p>
=== state: Couldn't read
note: Nothing has run yet today.
<p>broken</p>
SPEC
run states.sheet
[[ $rc -eq 0 ]] || fail "states: exit $rc: $err"
has states.html '>Normal</button>' "states: no letter on a state tab"
has states.html '>Couldn&#39;t read</button>' "states: the second tab"
has states.html '<h2 class="ux-name">Couldn&#39;t read</h2>' "states: the heading is the name"
has states.html '<p class="ux-cost">Nothing has run yet today.</p>' "states: the note"
lacks states.html 'class="ux-tag' "states: no tags"
pass "a states spec gives one unlettered tab for each state"

printf 'work: W\nheading: H\n=== state: Empty\n<p>none</p>\n' >one.sheet
run one.sheet
[[ $rc -eq 0 ]] || fail "one state: exit $rc: $err"
lacks one.html 'class="ux-tabs"' "one state: no tab row"
has one.html '<h2 class="ux-name">Empty</h2>' "one state: its name heads it"
printf 'work: W\nheading: The words, exactly\nsubheading: Every label on the tab\n\n<p>words: here</p>\nheading: not a key any more\n' >words.sheet
run words.sheet
[[ $rc -eq 0 ]] || fail "tabless: exit $rc: $err"
lacks words.html 'class="ux-tabs"' "tabless: no tab row"
has words.html '<h2 class="ux-name">Every label on the tab</h2>' "tabless: the subheading"
has words.html '<p>words: here</p>' "tabless: the drawing"
has words.html 'heading: not a key any more' "tabless: keys end at the first blank line"
has words.html '<h1 class="ux-heading">The words, exactly</h1>' "tabless: the heading"
pass "one drawing has the header and no tab row"

# --- refusals ----------------------------------------------------------------------------------

# refused <name> <wanted words> <spec text> [<args>...]
refused() {
  local name="$1" want="$2" text="$3"
  shift 3
  printf '%b' "$text" >"$name.sheet"
  run "$name.sheet" "$@"
  [[ $rc -eq 1 ]] || fail "$name: exit $rc, wanted 1: $out $err"
  [[ "$err" == "ux-sheet: "*"$want"* ]] || fail "$name: stderr names '$want', got: $err"
  [[ -z "$out" ]] || fail "$name: nothing on stdout, got: $out"
  [[ ! -e "$name.html" ]] || fail "$name: nothing is written"
}

o() { printf '=== option: %s\\ncost: c\\n%s\\n<p>x</p>\\n' "$1" "${2:-}"; }
head='work: W\nheading: H\n'
two="$(o a 'recommended: r')$(printf '\\n')$(o b)"
refused no-work "work:" "heading: H\n$two"
refused no-heading "heading:" "work: W\n$two"
refused one-option "two to four" "$head$(o a 'recommended: r')"
refused five-options "two to four" "$head$two\n$(o c)\n$(o d)\n$(o e)\n"
refused no-recommended "recommended" "$head$(o a)\n$(o b)\n"
refused two-recommended "recommended" "$head$(o a 'recommended: r')\n$(o b 'recommended: r')\n"
refused no-cost "cost:" "$head$(o a 'recommended: r')\n=== option: b\n<p>x</p>\n"
refused no-name "name" "$head$(o a 'recommended: r')\n=== option: \ncost: c\n<p>x</p>\n"
refused no-drawing "no drawing" "$head$(o a 'recommended: r')\n=== option: b\ncost: c\n\n"
refused empty-page "no drawing" "$head\n"
refused mixed "both" "$head$two\n=== state: Empty\n<p>x</p>\n"
refused bad-separator "=== option:" "$head$(o a 'recommended: r')\n=== Option: b\ncost: c\n<p>x</p>\n"
refused subheading-tabs "subheading:" "${head}subheading: s\n$two"
refused agreed-unknown "no option C" "$head$two" --agreed C
refused agreed-states "options" "$head=== state: a\nx\n=== state: b\ny\n" --agreed A
pass "a spec that breaks the frame's rules is refused by name, and nothing is written"

printf '%b' "$head$two" >self.html
run self.html
[[ $rc -eq 1 && "$err" == *"overwrite the spec"* ]] || fail "self: a spec is never overwritten, got $rc: $err"
grep -qF "=== option: a" self.html || fail "self: the spec is untouched"
run missing.sheet
[[ $rc -eq 1 && "$err" == *"no such file"* ]] || fail "missing: exit $rc: $err"
for args in "" "options.sheet extra" "options.sheet --agreed" "options.sheet --out" "options.sheet --nope"; do
  # shellcheck disable=SC2086
  run $args
  [[ $rc -eq 2 && "$err" == usage:* ]] || fail "usage '$args': exit $rc: $err"
done
pass "a spec is never overwritten, and a malformed call is a usage error"

suite_passed

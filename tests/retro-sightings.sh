#!/usr/bin/env bash
#
# Proves scripts/retro-sightings reads a corpus of retrospectives and reports each root cause the
# fleet has sighted at least `threshold` times (ah-qled.7.2, cerebro#58 §2).
#
# This is the port of scripts/retroSightings.test.ts from the consumer, and it is deliberately the
# specification rather than a description of the port: the parser has at least three cases - a
# `None found' paragraph naming beads as COUNTER-examples, a paragraph that wraps over several
# lines, and a sub-bead suffix that is not a sentence end - that a reimplementation-from-memory
# loses silently, turning the report wrong instead of failing.
#
# Every case is fed a fixture directory this test writes. The real corpus changes daily, so a test
# that reads it asserts today's fleet history rather than the parser.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/retro-sightings.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

sightings="$repo_root/scripts/retro-sightings"

# --- a stubbed `bd', so the dismissal and watermark memories are this test's, not the machine's ---
#
# The real script shells out to `bd remember'/`bd recall' exactly as the TypeScript did, and the
# key names are part of the contract (a dismissal made before the port must still be in force
# after it) - so the stub exercises that path rather than the script bypassing it.
stub_bin="$work_dir/bin"
mkdir -p "$stub_bin"
memories="$work_dir/memories"
mkdir -p "$memories"
cat > "$stub_bin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  config) echo "ah-" ;;
  recall)
    file="$MEMORY_DIR/${2:-}"
    [ -f "$file" ] || exit 1
    cat "$file"
    ;;
  remember)
    value="${2:-}"
    key=""
    shift 2 || true
    while [ "$#" -gt 0 ]; do
      case "$1" in --key) key="$2"; shift 2 ;; *) shift ;; esac
    done
    printf '%s\n' "$value" > "$MEMORY_DIR/$key"
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$stub_bin/bd"
export MEMORY_DIR="$memories"
export PATH="$stub_bin:$PATH"

# One retrospective, with the boilerplate the parser has to look past.
write_retro() {
  local dir="$1" bead="$2" date="$3" headline="$4" seen="$5"
  mkdir -p "$dir"
  cat > "$dir/$bead.md" <<RETRO
# $bead — retrospective

- **Implementer:** Cyclops
- **Date:** $date
- **PR:** #1

## $headline

**What happened.** Something.
**Why.** Not established.
**Cost.** An hour.
**Prevent by.** Nothing yet.
**Seen before.** $seen
RETRO
}

# A fresh fixture directory, named so a failure says which case it came from.
new_corpus() {
  local dir="$work_dir/corpus-$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  echo "$dir"
}

run() {
  local dir="$1"
  shift
  "$sightings" --dir "$dir" "$@"
}

# --- a Seen before paragraph that wraps across six lines is read whole ---
dir="$(new_corpus wrapped)"
mkdir -p "$dir"
cat > "$dir/ah-58dz.md" <<'RETRO'
# ah-58dz — retrospective

- **Date:** 2026-08-18

## the apt step hung

**Seen before.** ah-k6i.5 (same apt step, 20+ minutes),
ah-bn6.1,
ah-mjy,
ah-vw63,
and ah-3c80 — every one of them the same install,
which is probably what ah-8m0.2 hit.
RETRO
out="$(run "$dir")"
# Six ids across six lines, plus the bead that wrote them: seven.
grep -qE '^ +7 ' <<<"$out" \
  || fail "wrapped paragraph: expected one finding of 7, got: $out"
pass "a Seen before paragraph that wraps across six lines is read whole"

# --- a paragraph stops at the next bold run-in rather than swallowing it ---
dir="$(new_corpus runin)"
cat > "$dir/ah-aaa.md" <<'RETRO'
# ah-aaa — retrospective

- **Date:** 2026-08-14

## first

**Seen before.** ah-bbb,
ah-ccc.
**Prevent by.** ah-ddd should not be here.
RETRO
out="$(run "$dir")"
grep -qE '^ +3 ' <<<"$out" || fail "run-in: expected a finding of 3, got: $out"
grep -q 'ah-ddd' <<<"$out" && fail "run-in: swallowed the next run-in's bead id: $out"
pass "a paragraph stops at the next bold run-in rather than swallowing it"

# --- one paragraph per finding when a file holds two sections ---
dir="$(new_corpus twosections)"
cat > "$dir/ah-aaa.md" <<'RETRO'
# ah-aaa — retrospective

- **Date:** 2026-08-14

## first

**Seen before.** ah-bbb, ah-ccc

## second

**Seen before.** ah-ddd, ah-eee
RETRO
out="$(run "$dir")"
grep -qE '^ +5 ' <<<"$out" \
  || fail "two sections: both paragraphs should be read, got: $out"
pass "one paragraph per finding when a file holds two sections"

# --- a None found paragraph cites nothing, even when it names beads ---
#
# THE subtlest case: nine files in the real corpus name bead ids inside a negative paragraph as
# counter-examples, and reading those as citations silently merges unrelated components.
dir="$(new_corpus negative)"
write_retro "$dir" ah-aaa 2026-08-14 "one" "None found — ah-4ao is a different thing entirely."
write_retro "$dir" ah-bbb 2026-08-15 "two" "None found — ah-4ao again, and it is still unrelated."
write_retro "$dir" ah-ccc 2026-08-16 "three" "None found — ah-4ao, for the third time, unrelated."
out="$(run "$dir")"
grep -q 'No finding has been sighted three times' <<<"$out" \
  || fail "None found: negatives were read as citations, got: $out"
pass "a None found paragraph cites nothing, even when it names beads"

# --- a qualified None found still cites nothing ---
dir="$(new_corpus qualified)"
write_retro "$dir" ah-aaa 2026-08-14 "one" "none found for this one; ah-xxx is unrelated."
write_retro "$dir" ah-bbb 2026-08-15 "two" "Nothing like it yet, though ah-xxx looks similar."
write_retro "$dir" ah-ccc 2026-08-16 "three" "none found; ah-xxx, again, is not it."
out="$(run "$dir")"
grep -q 'No finding has been sighted three times' <<<"$out" \
  || fail "qualified negative: expected no finding, got: $out"
pass "a qualified None found still cites nothing"

# --- a bead id is read however it is written ---
dir="$(new_corpus shapes)"
write_retro "$dir" ah-aaa 2026-08-14 "one" \
  "ah-3c80, \`ah-csni\`, docs/retrospectives/ah-aao.md, and ah-2sy."
out="$(run "$dir")"
grep -qE '^ +5 ' <<<"$out" \
  || fail "id shapes: bare, backticked and path-shaped ids should all count, got: $out"
pass "a bead id is read however it is written"

# --- a sub-bead suffix is kept, not read as a sentence end ---
dir="$(new_corpus subbead)"
# Deliberately headline-less, so the finding is named by its ids and the suffixes are visible in
# the report rather than only in the count.
mkdir -p "$dir"
printf '**Seen before.** ah-8m0.2 and ah-k6i.5\n' > "$dir/ah-aaa.md"
out="$(run "$dir")"
grep -q 'ah-8m0\.2' <<<"$out" || fail "sub-bead: lost the .2 suffix, got: $out"
grep -q 'ah-k6i\.5' <<<"$out" || fail "sub-bead: lost the .5 suffix, got: $out"
pass "a sub-bead suffix is kept, not read as a sentence end"

# --- a chain of five beads about one cause is one finding of five ---
#
# The connected-components property. Grouping by citation pair gives four findings and looks
# entirely plausible.
dir="$(new_corpus chain)"
write_retro "$dir" ah-a 2026-08-14 "the apt step hung" "None found"
write_retro "$dir" ah-b 2026-08-15 "second" "ah-a"
write_retro "$dir" ah-c 2026-08-16 "third" "ah-b"
write_retro "$dir" ah-d 2026-08-17 "fourth" "ah-c"
write_retro "$dir" ah-e 2026-08-18 "fifth" "ah-d"
out="$(run "$dir")"
[ "$(grep -cE '^ +[0-9]+ ' <<<"$out")" = "1" ] \
  || fail "chain: expected exactly one finding, got: $out"
grep -qE '^ +5 ' <<<"$out" || fail "chain: expected a finding of 5, got: $out"
pass "a chain of five beads about one cause is one finding of five"

# --- a citation naming ids the cited bead already names does not inflate the count ---
dir="$(new_corpus transitive)"
write_retro "$dir" ah-3c80 2026-08-18 "the apt step hung" "ah-k6i.5, ah-bn6.1, ah-mjy, ah-vw63"
write_retro "$dir" ah-csni 2026-08-19 "the apt step hung again" \
  "ah-3c80 (which names ah-k6i.5, ah-bn6.1, ah-mjy, ah-vw63) — all the same step."
out="$(run "$dir")"
[ "$(grep -cE '^ +[0-9]+ ' <<<"$out")" = "1" ] \
  || fail "transitive: expected exactly one finding, got: $out"
grep -qE '^ +6 ' <<<"$out" || fail "transitive: expected a finding of 6, got: $out"
pass "a citation naming ids the cited bead already names does not inflate the count"

# --- a cited bead that wrote no retrospective of its own is still counted ---
dir="$(new_corpus uncited)"
write_retro "$dir" ah-b 2026-08-15 "second" "ah-a"
write_retro "$dir" ah-c 2026-08-16 "third" "ah-a"
out="$(run "$dir")"
grep -qE '^ +3 ' <<<"$out" \
  || fail "uncited: a cited bead with no file of its own still sighted it, got: $out"
pass "a cited bead that wrote no retrospective of its own is still counted"

# --- a cause sighted twice stays below the threshold ---
dir="$(new_corpus twice)"
write_retro "$dir" ah-a 2026-08-14 "one" "None found"
write_retro "$dir" ah-b 2026-08-15 "two" "ah-a"
out="$(run "$dir")"
grep -q 'No finding has been sighted three times' <<<"$out" \
  || fail "below threshold: two sightings is not a finding, got: $out"
pass "a cause sighted twice stays below the threshold"

# --- a finding is named by the oldest sighting's own headline ---
dir="$(new_corpus naming)"
write_retro "$dir" ah-c 2026-08-16 "the least useful description" "ah-a"
write_retro "$dir" ah-a 2026-08-14 "the apt step hung for twenty minutes" "None found"
write_retro "$dir" ah-b 2026-08-15 "middle" "ah-a"
out="$(run "$dir")"
grep -qE '^ +3 +ah-a: the apt step hung for twenty minutes +last: ah-c$' <<<"$out" \
  || fail "naming: expected the oldest headline and the newest bead, got: $out"
pass "a finding is named by the oldest sighting's own headline"

# --- and has no name when none exists ---
dir="$(new_corpus unnamed)"
for bead in ah-a ah-b ah-c; do
  printf '**Seen before.** ah-x\n' > "$dir/$bead.md"
done
out="$(run "$dir")"
grep -qE '^ +4 +ah-a, ah-b, ah-c, ah-x ' <<<"$out" \
  || fail "unnamed: a nameless finding is named by its ids, got: $out"
pass "a finding with no headline anywhere is named by its bead ids"

# --- biggest finding first, then most recent ---
dir="$(new_corpus ordering)"
write_retro "$dir" ah-a 2026-08-10 "small" "None found"
write_retro "$dir" ah-b 2026-08-11 "small" "ah-a"
write_retro "$dir" ah-c 2026-08-12 "small" "ah-a"
write_retro "$dir" ah-p 2026-08-20 "big" "None found"
write_retro "$dir" ah-q 2026-08-20 "big" "ah-p"
write_retro "$dir" ah-r 2026-08-20 "big" "ah-p"
write_retro "$dir" ah-s 2026-08-20 "big" "ah-p"
out="$(run "$dir")"
counts="$(grep -oE '^ +[0-9]+ ' <<<"$out" | tr -d ' ' | tr '\n' ' ')"
[ "$counts" = "4 3 " ] || fail "ordering: expected '4 3 ', got '$counts' from: $out"
pass "the biggest finding comes first, then the most recent"

# --- the report says how new the corpus is ---
grep -q 'every retrospective is new' <<<"$out" \
  || fail "watermark: with no watermark remembered, every retrospective is new, got: $out"
pass "with no watermark remembered, every retrospective is new"

# --- a dismissal silences the whole component, and is remembered through bd ---
dir="$(new_corpus dismissal)"
write_retro "$dir" ah-a 2026-08-14 "the apt step hung" "None found"
write_retro "$dir" ah-b 2026-08-15 "again" "ah-a"
write_retro "$dir" ah-c 2026-08-16 "again" "ah-a"
run "$dir" --dismiss ah-b > /dev/null
[ -f "$memories/retro-dismissed" ] \
  || fail "dismissal: nothing was remembered under the retro-dismissed key"
grep -q 'ah-b' "$memories/retro-dismissed" \
  || fail "dismissal: the key does not name the dismissed bead"
out="$(run "$dir")"
grep -q 'No finding has been sighted three times' <<<"$out" \
  || fail "dismissal: dismissing one bead silences its whole component, got: $out"
pass "a dismissal silences the whole component and is remembered through bd"

# --- dismissing a bead in no finding fails loudly rather than silencing nothing ---
if run "$dir" --dismiss ah-zzz > /dev/null 2>&1; then
  fail "dismissal: dismissing an unknown bead should exit non-zero"
fi
pass "dismissing a bead in no finding fails loudly"

# --- an absent corpus directory is an ordinary state, not a failure ---
out="$(run "$work_dir/no-such-dir")"
grep -q 'No finding has been sighted three times' <<<"$out" \
  || fail "absent corpus: expected the empty report, got: $out"
pass "an absent corpus directory reports nothing and exits 0"

echo "all retro-sightings tests passed"

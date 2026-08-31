#!/usr/bin/env bash
#
# Proves `scripts/session-marker.sh' is the one bash spelling of cerebro's marker sentence - the
# sentence `scripts/launch' puts at the head of every session's prompt and `scripts/agent-alive'
# cuts its two needles from:
#
#     This session is <Name> of the cerebro fleet rooted at <root>/. This sentence is how the
#     fleet view proves the session belongs to this checkout; do not remove it.
#
# The writer and one reader used to carry that text literally, one copy each. This suite pins the
# library's four functions against LITERALS written out here on purpose: a test that re-derived the
# sentence from the library it is testing would prove nothing at all, and byte-identity is the whole
# requirement - change the sentence and every running session goes dead.
#
# Three properties beyond the text itself, each already paid for elsewhere:
#   - the name needle ends at the space after "rooted at ", so `Cyclops' never matches `Cyclopsly'
#   - the root needle carries exactly one trailing slash, so `/repos/x' never matches `/repos/x-hud'
#   - the sentence carries no apostrophe: `scripts/launch' avoids one for its bash 3.2 convention,
#     and tests/fleet-cost.sh interpolates the field into a `sqlite3' string literal
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the repository root:
#
#     bash tests/session-marker.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

lib="$repo_root/scripts/session-marker.sh"
[[ -f "$lib" ]] || fail "scripts/session-marker.sh does not exist"

# Sourced, never executed - so it must not be executable, the same shape as scripts/root-hints.sh.
[[ ! -x "$lib" ]] || fail "scripts/session-marker.sh is sourced, so it must not be executable"

source "$lib"

# --- the sentence is byte-for-byte what the launcher used to write -------------------------------

want="This session is Cyclops of the cerebro fleet rooted at /tmp/root/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it."

got="$(cerebro_marker_sentence Cyclops /tmp/root)"
[[ "$got" == "$want" ]] || fail "the sentence must be byte-for-byte the launcher's, got: $got"
pass "the sentence is byte-for-byte what the launcher used to write"

# --- a root with a trailing slash gives one slash, not two ---------------------------------------

got="$(cerebro_marker_sentence Cyclops /tmp/root/)"
[[ "$got" == "$want" ]] || fail "a trailing slash on the root must be normalised, got: $got"
pass "a root with a trailing slash gives one slash, not two"

# --- the name needle ends at the space after "rooted at" -----------------------------------------

got="$(cerebro_marker_name_needle Cyclops)"
[[ "$got" == "This session is Cyclops of the cerebro fleet rooted at " ]] \
  || fail "the name needle must end at the space after 'rooted at ', got: [$got]"
pass "the name needle ends at the space after rooted at"

# It is the opening of the sentence, and it is what keeps a prefix name apart from a longer one.
case "$want" in
  "$got"*) ;;
  *) fail "the name needle must be the opening of the sentence" ;;
esac
case "$(cerebro_marker_sentence Cyclopsly /tmp/root)" in
  *"$got"*) fail "a session of Cyclopsly must not match Cyclops's name needle" ;;
  *) ;;
esac
pass "a name that is a prefix of another does not match the longer one"

# --- the root needle carries one trailing slash --------------------------------------------------

got="$(cerebro_marker_root_needle /tmp/root)"
[[ "$got" == "cerebro fleet rooted at /tmp/root/" ]] \
  || fail "the root needle must carry one trailing slash, got: [$got]"
pass "the root needle carries one trailing slash"

[[ "$(cerebro_marker_root_needle /tmp/root/)" == "$got" ]] \
  || fail "a root already carrying a slash must not gain a second one"
pass "the root needle normalises a root that already ends in a slash"

case "$want" in
  *"$got"*) ;;
  *) fail "the root needle must be a substring of the sentence" ;;
esac
case "$(cerebro_marker_sentence Cyclops /tmp/root-hud)" in
  *"$got"*) fail "a sibling root /tmp/root-hud must not match /tmp/root's needle" ;;
  *) ;;
esac
pass "a sibling checkout whose path merely starts with this one does not match"

# --- the infix is a substring of both needles ----------------------------------------------------

infix="$(cerebro_marker_infix)"
[[ "$infix" == "cerebro fleet rooted at" ]] || fail "the infix must be the name- and root-independent fragment, got: [$infix]"
case "$(cerebro_marker_name_needle Cyclops)" in
  *"$infix"*) ;;
  *) fail "the infix must be a substring of the name needle" ;;
esac
case "$(cerebro_marker_root_needle /tmp/root)" in
  *"$infix"*) ;;
  *) fail "the infix must be a substring of the root needle" ;;
esac
pass "the infix is a substring of both needles"

# --- the sentence carries no apostrophe ----------------------------------------------------------

case "$want" in
  *"'"*) fail "the sentence must carry no apostrophe" ;;
  *) ;;
esac
case "$(cerebro_marker_sentence Cyclops /tmp/root)" in
  *"'"*) fail "the sentence must carry no apostrophe" ;;
  *) ;;
esac
pass "the sentence carries no apostrophe"

suite_passed

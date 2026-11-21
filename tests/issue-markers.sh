#!/usr/bin/env bash
#
# Proves `scripts/issue-markers` (cb-ajvp): Moira's acknowledgement guard and status ladder read
# their hidden markers only from comments the account gh is authenticated as wrote. Anyone can
# comment on a public issue, so a marker in somebody else's comment must count for nothing, or a
# stranger's `<!-- moira-ack -->` silences the acknowledgement for good.
#
# `gh` is a stub answering `api user` and `issue view` from fixtures.
#
#     bash tests/issue-markers.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new repo --copy)"
markers="$consumer/.cerebro/cerebro/scripts/issue-markers"
stub="$work_dir/stub"
mkdir -p "$stub"

cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "api user")
    [[ -e "$STUB_DIR/user-fails" ]] && { echo "gh: HTTP 401: Bad credentials" >&2; exit 1; }
    cat "$STUB_DIR/login" ;;
  "issue view")
    [[ "$3" == 7 ]] || { echo "gh: could not find issue $3" >&2; exit 1; }
    cat "$STUB_DIR/issue.json" ;;
  *) echo "issue-markers stub: unexpected gh $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub/gh"

# comment <author> <body> - one comment as `gh issue view --json comments` prints it.
comment() { jq -cn --arg a "$1" --arg b "$2" '{author: {login: $a}, body: $b}'; }
thread() { jq -cs '{comments: .}' <<<"$(printf '%s\n' "$@")" > "$stub/issue.json"; }
run() { (cd "$consumer" && STUB_DIR="$stub" PATH="$stub:$PATH" bash "$markers" "$@"); }

echo moira-bot > "$stub/login"

# --- a stranger's markers count for nothing ------------------------------------------------------

thread "$(comment reporter $'It crashes.\n<!-- moira-ack -->')" \
       "$(comment stranger $'ha\n<!-- beads-state:RELEASED -->')"
out="$(run 7)" || fail "issue-markers failed on a readable thread"
[[ -z "$out" ]] || fail "markers from comments Moira did not write were counted: $(printf '%q' "$out")"
pass "a stranger's moira-ack and beads-state markers are ignored"

# --- Moira's own markers, in thread order, with a stranger's in between ignored -----------------

thread "$(comment moira-bot $'Thanks.\n<!-- moira-ack -->')" \
       "$(comment moira-bot $'Tracked.\n<!-- beads-state:CREATED -->')" \
       "$(comment stranger $'<!-- beads-state:RELEASED -->')" \
       "$(comment moira-bot $'Designed.\n<!-- beads-state:DESIGNED -->')" \
       "$(comment moira-bot 'We talk about beads-state:MERGED and moira-ack without the comment form.')"
out="$(run 7)"
expected=$'moira-ack\nbeads-state:CREATED\nbeads-state:DESIGNED'
[[ "$out" == "$expected" ]] || fail "expected Moira's three markers in order, got: $(printf '%q' "$out")"
pass "Moira's own markers come back in thread order, and only in their comment form"

# --- an unreadable login or issue is a failure, never an empty answer ----------------------------

touch "$stub/user-fails"
if run 7 >/dev/null 2>&1; then fail "a failed gh api user was answered with exit 0"; fi
rm "$stub/user-fails"
: > "$stub/login"
if run 7 >/dev/null 2>&1; then fail "an empty login was answered with exit 0"; fi
echo moira-bot > "$stub/login"
if run 8 >/dev/null 2>&1; then fail "an unreadable issue was answered with exit 0"; fi
pass "an unreadable login or issue fails rather than reading as 'no markers'"

if run >/dev/null 2>&1; then fail "no issue number was accepted"; fi
pass "an issue number is required"

suite_passed

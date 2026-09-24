#!/usr/bin/env bash
#
# Proves `scripts/bead-delivery.sh`: the one place bash answers "did this bead's work reach the
# default branch" (cb-10d.4), extracted unchanged in behaviour from the retired claims sweep.
#
#     bash tests/bead-delivery.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new delivery --origin --link project-conf default-branch consumer-root bead-delivery.sh)"
scripts="$consumer/.cerebro/cerebro/scripts"

commit() {
  git_q -C "$consumer" commit -q --allow-empty -m "$1"
}
push() {
  git_q -C "$consumer" push -q origin HEAD:main
  git_q -C "$consumer" fetch -q origin main
}
delivered() {
  (script_dir="$scripts"; source "$script_dir/bead-delivery.sh"; cerebro_bead_delivered "$consumer" main "$1")
}

commit "feat(cb-x): done"
commit "feat(cb-p.1): child"
commit "docs(cb-m): mockup"
commit "PROJ-9 done: it"
push

delivered cb-x || fail "a conventional subject on origin is delivery"
pass "a conventional subject on origin is delivery"

if delivered cb-p; then fail "a child's commit is not its parent's delivery"; fi
pass "a child's commit is not its parent's delivery"

delivered cb-m || fail "a mockup commit alone is delivery when nothing is declared"
pass "a mockup commit alone is delivery when nothing is declared"

printf 'non_delivery_commit_pattern docs({id}): mockup\n' > "$consumer/.cerebro/project.conf"
if delivered cb-m; then fail "a declared non-delivery pattern excludes the mockup"; fi
commit "feat(cb-m): the real work"
push
delivered cb-m || fail "a real commit beside the mockup is delivery"
pass "a declared non-delivery pattern excludes the mockup"

printf 'commit_ref_pattern {id} done:\n' > "$consumer/.cerebro/project.conf"
delivered PROJ-9 || fail "commit_ref_pattern substitutes the id anywhere"
pass "commit_ref_pattern substitutes the id anywhere"
rm -f "$consumer/.cerebro/project.conf"

commit "feat(cb-local): not pushed"
if delivered cb-local; then fail "a commit only on a local branch is not delivery"; fi
pass "a commit only on a local branch is not delivery"

for flags in -euo -uo; do
  status=0
  out="$(bash "$flags" pipefail -c '
    script_dir="$1"; source "$script_dir/bead-delivery.sh"
    if cerebro_bead_delivered "$2" main cb-none; then echo yes; fi
    echo after' _ "$scripts" "$consumer")" || status=$?
  [[ $status -eq 0 && "$out" == "after" ]] || fail "bash $flags pipefail: got $status: $out"
done
pass "it answers the same under set -e and without it"

suite_passed

# cb-b4m — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-26
- **PR:** #169

## The plan's first two increments had already shipped, and it quoted the pre-fix code as current

**What happened.** The plan's *Files to change* section opened with `cerebro--park-session`, quoted
its body under the heading "Currently:", and asked for two things: bind `vterm-kill-buffer-on-exit`
to nil before `delete-process`, and re-check `buffer-live-p` after it. Increments 1 and 2 were the
failing tests for those two changes. Both were already in main. cb-kqz (#167) had merged the
afternoon the plan was written and had solved the same `Selecting deleted buffer` mechanism a
different way — binding the variable buffer-locally in `cerebro--make-session-buffer` after
`vterm-mode` rather than inside the park — with two ERT cases already standing
(`session-buffer-outlives-its-process`, `park-keeps-what-it-can-when-killing-the-process-kills-the-buffer`).
Read literally, increments 1 and 2 were RED tests for code that was already GREEN.

**Why.** Established. The plan quoted a snapshot of `emacs/cerebro.el` taken during planning and was
not re-read against main at claim time; `git log --oneline -5 -- emacs/cerebro.el` at the top of the
run shows `340711b fix(cb-kqz)` as the last commit to the file.

**Cost.** About fifteen minutes, all of it reading — the two increments were skipped rather than
built, so no CI cycle and no wrong code. The cost of *not* noticing would have been larger: two
duplicate tests and an edit to a function whose bug was gone.

**Prevent by.** `skills/implement-bead`, *When the plan is wrong*, already says a helper a plan cites
for what it decides is read before it is built on. Extend that to code a plan **quotes as current**:
a `Currently:` block, a "becomes" diff, a line number. Before writing an increment's failing test,
open the quoted region in the worktree and check it still reads as quoted — one `sed -n`. A quote is
a claim about main at planning time, and a bead is planned in one session and built in another, so
main has usually moved. Where it has, the increment is finished and the deviation goes in the PR body
rather than the hand-back block: this is a detail overtaken, not the plan being wrong about approach.

**Seen before.** `cb-5yr.3` — a plan's verbatim paragraph made a false claim about what its sibling
bead had just shipped. `ah-kjfm` — a bead that merged mid-run changed a fixture under the running
bead. Same family, third sighting: a plan is a photograph of main, and the fleet keeps moving.

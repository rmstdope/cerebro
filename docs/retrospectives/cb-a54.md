# cb-a54 — retrospective

- **Implementer:** Storm
- **Date:** 2026-09-03
- **PR:** #293

## A plan-stated conversion rule would have shrunk the bound in the very test the bead exists to protect

**What happened.** The plan's *test plan* gave an explicit rule for converting the attempt-count
loops (`for _ in 0..40 { …; sleep(50ms) }`) into time bounds: *"Convert each by multiplying count ×
interval."* I applied it literally, so `main.rs::apply_until` became
`probe::wait_for(Duration::from_secs(2), …)`. The cold-read review's first finding was that the
identity only holds when an attempt costs nothing, and this attempt is
`readers::read_configured_supervisor`, which **forks the `fleet-supervisor` bash script**. The old
loop's real wall clock was 40 × (fork + 50ms) — four to six seconds; the new one was a hard 2s
*including* the forks, so the deadline genuinely moved earlier. `apply_until` is called by
`a_real_emacs_releases_on_the_declaration_and_this_process_takes_it` — the case cb-kcs.5.3 spent
about 25 minutes diagnosing for being one attempt short. `supervisor.rs::acquire_once_free` had the
same defect, smaller, because its attempt only binds a socket.

**Why.** Established. `count × interval` measures only the *sleeping*, and every one of these loops
sleeps *after* doing work. The rule is exact for a free attempt and increasingly wrong as the
attempt gets more expensive; a forked bash script is at the expensive end.

**Cost.** One review round and one CI cycle, perhaps fifteen minutes — cheap only because the
reviewer caught it. Had it merged, the cost would have been the next intermittent red run of the
cutover test, which the same class of defect has already priced at 25 minutes twice.

**Prevent by.** A plan that converts an attempt-count loop to a time bound should give the rule as
*count × (interval + what one attempt costs)*, or simply name the bound per site — and where the
attempt forks a process or binds a socket, say so beside the site. `skills/plan-bead`'s test-plan
guidance is where that belongs. The narrower lesson, which is now a comment at both converted sites:
**a bound is the wall clock the case gets, not an attempt budget**, so converting one by arithmetic
over the old loop's sleeps silently changes what the case can survive.

**Seen before.** cb-kcs.5.3 and cb-kcs.5.4 — both flakes in this same family of waits, and both
named in this bead's own evidence. This is the third sighting of "a hand-written bound was one
attempt short", which is what the bead was filed to end; it is worth recording that the *fix* very
nearly reintroduced it.

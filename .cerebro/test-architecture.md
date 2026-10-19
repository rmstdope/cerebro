# Test architecture

Agreed with the navigator 2026-10-19.

## Unit             fleet-view/src/{model,sweeps,give,app,ui,lifecycle,triggers,supervisor,history}.rs, #[cfg(test)]
  Belongs here:    pure decisions — parsing, derivation, sweeps, triggers, what to draw — over plain data and an injected clock
  Not here:        files, processes, ptys, the real clock
  Enough is:       every branch of a decision once; a decision shared with bash, once per row of its tests/lib table

## Edge             fleet-view/src/{readers,session,log,main}.rs tests, fleet-view/tests/*.rs, web-console/tests/*.rs
  Belongs here:    the impure edge — CommandRunner, ptys, log files, the lease listener, the web service — each child under a wall-clock bound
  Not here:        a decision the core makes, asserted again; waiting on the real clock to count time
  Enough is:       each way a read, a child or a request can fail, once

## Script           tests/*.sh, against a throwaway consumer under $work_dir
  Belongs here:    one script's behaviour, run for real in a fabricated consumer with bd, gh and the agent CLI stubbed
  Not here:        prose — agent files, skills, docs are never grepped; a behaviour another script's suite already proves
  Enough is:       each case a script decides, once, in that script's own suite

## Browser          web-console/ui/tests/*.spec.ts (Playwright)
  Belongs here:    what the web console shows and does in a browser
  Not here:        the service's own reads and failures (Edge)
  Enough is:       each screen and each action once

## System           tests/*.sh, each named on its requirement's Proven by: line in .cerebro/requirements.md
  Belongs here:    one requirement each — the whole path a person takes, in a throwaway consumer
  Not here:        a script's own refusals and edge cases (Script)
  Enough is:       every requirement once

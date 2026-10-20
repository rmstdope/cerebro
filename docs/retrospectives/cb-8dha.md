# cb-8dha — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-10-20
- **PR:** #498

## A new fleet-view system suite went read-only beside fleet-keys in the local gate, alone it was green

**What happened.** `tests/fleet-type.sh` passed alone. In `bash tests/gate` it showed `this window could not take charge of the fleet`. Run beside `tests/fleet-keys.sh` it failed every time, and fleet-keys sometimes failed with it. `fleet-supervisor --endpoint` gave `127.0.0.1:24187` for both consumers (`<mktemp>/type` and `<mktemp>/keys`).

**Why.** cb-7jmm: the lease port is a function of the root's length alone, and `type` and `keys` are both four letters. I worked this out from scratch and filed it again as cb-ebqd before finding cb-eguq's retrospective, which already names it. cb-ebqd is closed as a duplicate. The suite now names its consumer `typing`, a length no other view suite uses, until cb-7jmm lands.

A second, separate cause kept the local gate red after the rename: about 20 `suite-runner` processes from other sessions were running on the machine (load 15–20). Every pty suite, fleet-board on main's own code included, then timed out on a 5 s script read or a 20 s start. CI, with one gate per runner, was green.

**Cost.** About 40 minutes and three full local gate runs spent diagnosing an already-known defect, plus one duplicate bead.

**Prevent by.** Before filing or diagnosing a red that is local only, grep `docs/retrospectives/` for the symptom's on-screen words ("could not take charge", "read-only"). That is produce-bead's *The retrospective* grep, run at diagnosis time rather than after review. Until cb-7jmm merges, a new fleet-view system suite needs a consumer name whose length no other `--copy` view suite uses (`keys` 4, `board` 5, `typing` 6, `restart` 7).

**Seen before.** cb-eguq (the cause, cb-7jmm), cb-gyw0 (fleet-view-restart red locally under load, green in CI).

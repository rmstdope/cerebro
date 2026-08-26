# Variant A — topic by topic, each pinned before the next

The session announces itself, checks the repository is blank, then walks five topics in a fixed
order. Every answer gets at least one follow-up; a topic ends when the session can read back a
sentence the navigator agrees with. project.conf is confirmed at the end, then the epics.

---

**Session:** I am the project-definition session. The board has no open beads and the tree holds
only README.md and the harness, so this is a blank project. I will ask about the software as a
whole — what it is, where it runs, what it is built with, what using it is like — and then about
the first epics. Expect follow-ups; I stop on a topic only when I can read it back to you.

**1. What is it?**
> What kind of software is this — a CLI, a service, a library, a desktop or mobile app, a harness
> like cerebro, something else? One sentence on who uses it and for what.

*Navigator:* A web app for tracking climbing routes I've set.

> Follow-up: one person's own log, or several setters sharing a wall? Does anyone but a setter ever
> look at it — climbers, a gym manager?

*(…two more follow-ups; then:)*

> Read-back: *A multi-user web app where route setters at one gym log the routes they set, and
> climbers browse them read-only.* Right?

**2. Where does it run?**
> How is it deployed, and to what — a host you rent, a container platform, a static bundle on a
> CDN, an app store, a package registry? Who runs the deploy, and how often?

*(follow-ups: single environment or staging+prod; where the data lives; what "down" means)*

**3. What is it built with?**
> Which stacks are on the table? And which have you already ruled out, and why — the ruled-out
> ones matter as much, because a planner will otherwise propose them.

*(follow-ups: language, framework, database, test runner, package manager; the gate command; what
"installed" means on a fresh clone)*

**4. What is using it like, and what does it look and feel like?**
> Walk me through the first minute for each kind of user. What do they see first, what is the one
> thing they came to do, what does done look like?

*(follow-ups: the empty state on day one; auth or no auth; what a mistake looks like and how it is
undone; visual style, platform conventions, accessibility, the three words it must feel like)*

**5. The declaration**
> From the above I would write `.cerebro/project.conf` as:
> ```
> project_name   Crux
> default_branch main
> audience_noun  setter
> app_paths      ^(src|public)/
> gate_fast      pnpm test
> gate_full      pnpm test && pnpm build
> install        pnpm install --frozen-lockfile
> ```
> Anything wrong?

**6. The first epics**
> What has to exist before anyone can use this at all? Name the opening arcs; I will propose the
> children each obviously carries and you strike or add.

*(per epic: read-back, obvious children, then the rank — P0–P4 — for the epic; children follow it)*

**Close:** files written, beads created (ids and titles listed), and the two commands left to the
navigator: `git add -A && git commit`, and starting a planner.

---
name: delegate
description: Load before launching two or more subagents or sessions, any subagent in the background, or a separate session for part of the work, and when choosing which model or pool a subagent or session should run on. Covers this machine's pools (small, speed, scout, workhorse, specialist, summit, background) and direct models; inline vs subagent vs background subagent vs nested subagents vs a separate OpenChamber session with its own worktree; fan-out shapes (a summit lead with area sessions, a cheap supervisor over strong workers); and supervising them through comms until every result is verified. Use to split or fan out work across agents, run research or review passes in parallel or in the background, hand an area to its own session or branch, let subagents launch subagents, or pick summit, workhorse or a fast model for a piece. Not for changing the pools (routing-config) or a repository's PR and merge rules (its own skill, such as operations-portal's orchestrate).
---

# Delegate: models, subagents and sessions

The rules, and the incidents behind them, are in
`~/.config/opencode/instructions/work-strategies.md` (section Delegation). This skill is the
procedure: what to launch, on which model, and how to keep it moving. A repository's own skill
(operations-portal's `orchestrate`) still owns its PR, merge and deploy rules; load both.

## Steps

1. **Check what already exists.** `gh pr list`, `git worktree list`, recent branches, and live
   sessions (in `execute`: `tools.comms.sessions({ mode: "list", active: true })`). Done when nothing
   you are about to launch is already running, merged, or half-done in another worktree.
2. **Cut the work into pieces with one owner each.** For each piece write down what it changes (paths,
   or "read-only"), its branch and worktree if it writes, what it returns, and what it may decide.
   Two pieces that write the same files are one piece. An interface two pieces share goes in a file
   before either starts. Done when every piece has an owner-to-be and a deliverable.
3. **Pick a model per piece** ([Models](#models)). Done when each piece has a pool or a direct model,
   chosen by what that piece must decide, not by what you run on.
4. **Pick a vehicle per piece** ([Vehicles](#vehicles)). Done when each piece is inline, a subagent, a
   background subagent, or a session.
5. **Pick a shape** ([Shapes](#shapes)): who leads each level, who integrates, who talks to whom. Done
   when every writing piece has a named integrator.
6. **Brief each one for a cold start.** Start from `~/git/cairn/prompts/snippets/subagent-brief.md`;
   add the model, how to report (final message, `tools.comms.msg({ to: "parent", text })`, or a
   topic), and what it may decide alone. A session started with `ownWork` cannot ask the user: tell it
   to message its parent, or to record the question with a default and continue. Done when someone
   with no context could start from the brief alone.
7. **Launch everything independent at once, in the background.** One message with every launch, then
   work on something that does not overlap, or end your turn. Do not poll and do not sleep. Done
   when everything is running.
8. **Supervise until done** ([Supervision](#supervision)). Done when you have verified every
   deliverable yourself, integrated it, and archived every `ownWork` session.
9. **Record what the shape taught you**: the shape, the models, wall time, what broke
   (`~/.config/opencode/instructions/recordings.md`). Done when appended, or skipped on purpose.

## Models

`node ~/.agents/skills/delegate/scripts/pools.mjs` prints the live pools: every leg in failover
order, the model and effort behind it, and its Artificial Analysis score and minutes per task. It
reads `~/.config/opencode/opencode.jsonc` and exits 1 with a warning when the table below no longer
names the configured pools; `--diff ~/.config/nix/opencode-global.jsonc` checks the tracked mirror
of the routing against the live file. Weakest and fastest first:

<!-- pools:begin: pools.mjs checks these names, in this order, against the config -->

| Pool         | Speed    | Use it for                                                                                           |
| ------------ | -------- | ---------------------------------------------------------------------------------------------------- |
| `small`      | fastest  | lookups, greps, status checks, renames and other mechanical edits; a supervisor that decides nothing |
| `speed`      | fast     | small well-specified edits, summaries, triage, formatting fixes                                      |
| `scout`      | fast     | exploring and reading code, research, first drafts; a light supervisor                               |
| `workhorse`  | moderate | implementation, tests, refactors, review rounds: the default for writing code                        |
| `specialist` | slow     | hard bugs, tricky design, deep review                                                                |
| `summit`     | slowest  | the hardest calls: architecture, cross-cutting decisions, final review; a lead that integrates       |
| `background` | slowest  | long work nobody is waiting on (inferred from its name; the config does not say)                     |

<!-- pools:end -->

- Call a pool as `opencode-route/<pool>` with **no effort**. Every leg pins its own effort, so a pool
  offers none (the comment at the top of `opencode.jsonc` explains the mechanism).
- Any model can be called directly: `github-copilot/<id>#<effort>`, such as
  `github-copilot/claude-sonnet-5.5#high`, or through its per-model route,
  `opencode-route/<name>#<effort>`; `pools.mjs` lists both. In `execute`,
  `tools.openchamber({ action: "models.available", parameters: {} })` lists every id with its efforts.
- A child given no model inherits its parent's. Pass one every time.
- A repository can set its own policy, and inside it that wins: developing-today/code dispatches
  subsessions on `workhorse` and escalates by a fresh launch with the reason recorded
  (`.opencode/instructions/routing-policy.md` there).
- The `background` pool is a model. `background: true` is a way of launching a subagent. They are
  unrelated.
- A pool fails over to its next leg on errors. Failure rates, benches and slow legs: `route_stats`
  (routing-review skill). Changing a pool: routing-config skill.

## Vehicles

| Vehicle             | When                                                                               | How                                                                                                                   |
| ------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Inline              | you already hold the context and it is a few lines                                 | do it                                                                                                                 |
| Subagent            | a bounded task whose answer you need back                                          | `subagent` tool with `agent` (`explore` to search and read, `general` for the rest), `model`, `description`, `prompt` |
| Background subagent | the same, while you do other work                                                  | add `background: true`; its result arrives as a new turn                                                              |
| Separate session    | a workstream with its own branch, PR or fan-out, or a life longer than a few turns | OpenChamber `session.create`, below                                                                                   |
| Scheduled session   | a check that recurs                                                                | `openchamber schedule create --dir <repo> --name <n> --prompt <p> --model opencode-route/small --cron '<expr>'`       |

**Subagents.** `stopPolicy` decides what interrupting you does to a background child: `independent`
(the default) keeps it running, `cascade` stops it with you, and `detached` survives even a cascading
stop and needs a force-stop. Continue a finished child by passing its `sessionID`; after about five
idle minutes a fresh child with a brief is probably cheaper than re-waking a large context (an
inference from measured cache costs in cairn's agent-practices, not tested as a rule). A writing
subagent starts in your directory: give it its own worktree, or disjoint files in yours that you
commit.

**Nesting.** A subagent can launch its own, up to `experimental.subagent_depth` levels (10 here);
each session's subagent tool states how many levels remain. If a child reports that it cannot launch
one, check that key: OpenCode v2 silently falls back to 1 when it is misplaced (comment in
`opencode.jsonc`). Each session can also run its own subagents.

**Sessions.** From `execute`, when `tools.openchamber` is in the Code Mode catalog
(`search("openchamber")` tells you). It comes from OpenChamber, and can be missing: in a session
OpenChamber did not start, and, observed on 2026-11-24, for the rest of a session after its OpenCode
server restarted, while `tools.comms` stayed.

```js
await tools.openchamber({
  action: "session.create",
  parameters: {
    prompt: "<the brief>",
    model: "opencode-route/summit",
    worktree: "billing-api", // a new worktree under ~/.local/share/opencode/worktree/<project>/
    branch: "feat/billing-api",
    ownWork: true, // nests under you; each answer it ends a turn with comes back to you
  },
});
```

- Leave out `ownWork` when the user wants to follow and talk to the session themselves.
- `goal: true` runs it in Goal Mode; set it only when the user asked for Goal Mode.
- `subagentPolicy: { models: [...] }` limits which models its own subsessions may run.
- Without `tools.openchamber`, the shell does the same: `openchamber session create --dir <repo>
--worktree <name> --branch <branch> --json`, then `openchamber session send --session <id> --dir
<its directory> --prompt "<brief>" --model opencode-route/workhorse`; `openchamber session status`
  and `openchamber session messages --last-assistant` read it back.
- The CLI fallback does not expose `ownWork` or automatic parent-result delivery. Keep its returned
  session ID and supervise it explicitly; do not claim it is nested or will notify you automatically.
- Archive an `ownWork` session once you have used its result (`session.archive`).

**Comms.** In `execute` only; `mcpx_exec` does not reach it, whatever its description says (the
mcpx-scripts skill has the reproduction).

- `tools.comms.msg({ to: "<session id>" | "parent" | "root", text })` delivers the message and wakes
  the recipient.
- Topics: `family` (your parent and all its subsessions), `children` (you and yours), `tree`
  (everything under your root), `dm@<session>`, `tasks`. Topic messages are read on demand unless
  the reader subscribed (`tools.comms.topics({ mode: "subscribe", topic })`).
- `tools.comms.msg({ mode: "unread", wait: 60 })` waits up to 60 seconds for a reply.
- `tools.comms.sessions({ mode: "log", session: "<id>", op: "tail" })` reads any session's log without
  waking it.
- A delivered message wakes its recipient: send what needs an answer or changes a plan, never a bare
  acknowledgement.

## Shapes

The tree does not have to be strict. Any session can message any other, so siblings can settle
things between themselves, and a lead only handles what crosses its children.

- **One agent.** Sequential work with tight back-and-forth. Multi-agent work helps parallel tasks,
  hurts sequential ones, and costs several times the tokens (cairn's agent-practices).
- **Lead and workers.** A lead briefs workers on disjoint pieces, verifies what they return and
  integrates it: the shape in work-strategies. The lead's model matches what integration needs.
- **Strong tree.** A `summit` lead starts `summit` or `specialist` area leads, one session and worktree
  each; they run `workhorse` implementers, which call `scout` or `small` helpers for lookups. Every
  level makes real decisions for its subtree and integrates its children. For a large change whose
  areas each need design judgement.
- **Cheap hub, strong spokes.** A `small` or `scout` session starts three to six `workhorse`,
  `specialist` or `summit` sessions, as sessions or subagents, and each of those leads its own
  helpers. The hub decides nothing about code: it checks progress, nudges idle sessions, restarts
  failures, collects reports, and passes decisions to the area that owns them, a strong reviewer, or
  the user. For areas that are independent (separate repositories, disjoint modules) or coordinate
  among themselves through comms. Probably faster and cheaper than a slow model tending the same
  sessions, since each wake of the hub is a short turn on a small context; that is a judgement, not
  measured here, so record how it goes.
- **Mesh.** Peers coordinate on a topic: whoever produces an interface posts it, whoever consumes it
  subscribes. Still name one integrator.

Three questions pick the shape. Who integrates? That node needs judgement, so a strong model. Do two
pieces write the same files? Partition first, or make them one piece. Does a worker need answers
mid-way? Then its parent must be cheap to wake, or the answer goes in the brief.

## Supervision

On every wake (a result, a message, a timer):

1. **List your sessions.** `tools.openchamber({ action: "session.list", parameters: { mine: true } })`
   gives each one's status (shell: `openchamber session list --with-status --json`); background
   subagents report when they finish.
2. **Act on each.** Busy: leave it. Idle and not done: read its last answer (`session.messages` with
   `lastAssistant: true`), then `session.send` "continue; report what is done, what remains, what
   blocks you". Waiting on the user: pass the question up with your proposed default. Failed: read
   its log tail, then `session.retry`, or start a fresh session with a corrected brief.
3. **Verify what it says is done.** Branch pushed, PR open, checks read, the claim re-run. A final
   message is not proof of exit: `git log origin/main..HEAD`, `git status --short`,
   `git ls-remote --heads origin <branch>`. Then archive it.
4. **Nothing to act on:** `tools.openchamber({ action: "wait.start", parameters: { source: "timer",
args: { minutes: 15 } } })`, or `source: "pr"` with `args: { url }`, and end your turn.

A hub routes design questions to the area that owns them, a strong reviewer or the user; it does not
answer them itself.

## Checking this skill

`evals/triggers.json` contains should-load and near-miss prompts. From darwin-nix, run
`node scripts/skill-trigger-eval.mjs .agents/skills/delegate/evals/triggers.json --trials 3 --out <file>`.
The saved `results-2026-11-24-1.json` and `-2.json` preserve both rounds, including every miss and
session ID. These measure first-step loading in a permission-restricted fresh session, not successful
orchestration. Several short questions are answered from the always-loaded summary without loading
this skill. Do not equate that score with task correctness or claim perfect triggering.

`node --test .agents/skills/delegate/scripts/pools.test.mjs` verifies the JSONC reader, table drift
and routing comparison against independent literal expectations. A stale table or changed pool
must fail; copying the implementation's output into an expected snapshot would defeat that check.

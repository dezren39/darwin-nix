#!/usr/bin/env node
// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Skill trigger eval: does a fresh OpenCode session load a skill for the
// requests in its evals/triggers.json (should_load), and leave it alone for
// the near misses (should_not_load)? cairn's skill-writer step 7 asks for
// about three trials of each request in fresh sessions; this runs them.
//
//   node scripts/skill-trigger-eval.mjs .agents/skills/<name>/evals/triggers.json \
//     [--trials 3] [--model github-copilot/claude-opus-5.5] [--concurrency 3] [--out results.json]
//
// Each trial is `opencode run --format json --archived` in a scratch
// directory whose project config (written below) keeps every tool VISIBLE
// but refuses every call except `skill`: deny everything, then allow every
// action for one resource nothing ever uses. A deny-all or ask-all rule set
// was tried first and hides the tools, so the model sees only `skill` and
// loads it far more readily than a real session would (measured 2026-11-24:
// asked to list its tools, it answered "skill"). With the dummy-resource rule
// it listed all 23 tools, and `touch marker.txt` came back "Permission
// denied: shell" without creating the file. `steps: 2` ends a trial after the
// first model step and a forced summary, so a trial costs at most two
// requests and nothing it asks for runs.
//
// Skills come from wherever the live OpenCode finds them (~/.agents/skills,
// the configured skills paths); the scratch directory adds none of its own,
// so a request meant for a repository's own skill is tested outside that
// repository.
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = argv.indexOf(name);
  if (i < 0) return fallback;
  const value = argv[i + 1];
  if (value === undefined || value.startsWith("--"))
    usage(`${name} needs a value`);
  argv.splice(i, 2);
  return value;
};
function usage(message) {
  console.error(
    `${message}\nusage: skill-trigger-eval.mjs <triggers.json> [--trials N] [--model provider/model] [--concurrency N] [--out file]`,
  );
  process.exit(2);
}
const trials = Number(flag("--trials", "3"));
const model = flag("--model", "github-copilot/claude-opus-5.5");
const concurrency = Number(flag("--concurrency", "3"));
const outPath = flag("--out", undefined);
if (argv.length !== 1 || argv[0].startsWith("-"))
  usage("expected exactly one triggers.json");
// Catch Infinity, fractions and accidental huge trial counts before any
// launches or sandbox writes. Caps prevent a typo spending thousands of
// model requests; the intended default is three trials and three workers.
if (!Number.isSafeInteger(trials) || trials < 1 || trials > 100)
  usage("--trials must be an integer from 1 to 100");
if (!Number.isSafeInteger(concurrency) || concurrency < 1 || concurrency > 32)
  usage("--concurrency must be an integer from 1 to 32");

const evals = JSON.parse(readFileSync(argv[0], "utf8"));
const skill = evals.skill;
if (
  typeof skill !== "string" ||
  skill.length > 64 ||
  !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(skill)
)
  usage("invalid skill name");
if (
  !Array.isArray(evals.should_load) ||
  evals.should_load.length === 0 ||
  !evals.should_load.every((s) => typeof s === "string" && s.trim())
)
  usage("should_load must contain nonempty request strings");
if (
  !Array.isArray(evals.should_not_load) ||
  evals.should_not_load.length === 0 ||
  !evals.should_not_load.every(
    (c) => typeof c.request === "string" && c.request.trim(),
  )
)
  usage("should_not_load must contain nonempty request strings");
const cases = [
  ...evals.should_load.map((request) => ({ request, expect: true })),
  ...evals.should_not_load.map((c) => ({
    request: c.request,
    expect: false,
    loadInstead: c.load_instead,
  })),
];

const sandbox = join(tmpdir(), `skill-trigger-eval-${skill}-${process.pid}`);
mkdirSync(join(sandbox, ".opencode"), { recursive: true });
writeFileSync(
  join(sandbox, ".opencode", "opencode.jsonc"),
  JSON.stringify(
    {
      $schema: "https://opencode.ai/config.json",
      agents: {
        build: {
          steps: 2,
          permissions: [
            { action: "*", resource: "*", effect: "deny" },
            {
              action: "*",
              resource: "__skill_trigger_eval_noop__",
              effect: "allow",
            },
            { action: "skill", resource: "*", effect: "allow" },
          ],
        },
      },
    },
    null,
    2,
  ),
);

function trial(request, label) {
  return new Promise((resolve) => {
    const child = spawn(
      "opencode",
      [
        "run",
        "--format",
        "json",
        "--archived",
        "--title",
        label,
        "--model",
        model,
        request,
      ],
      { cwd: sandbox, stdio: ["ignore", "pipe", "pipe"] },
    );
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    let spawnError;
    child.once("error", (error) => {
      spawnError = error.message;
    });
    let killTimer;
    const timer = setTimeout(() => {
      spawnError =
        "opencode client timed out after 300 seconds; inspect any reported session before continuing it";
      child.kill("SIGTERM");
      killTimer = setTimeout(() => child.kill("SIGKILL"), 5_000);
    }, 300_000);
    child.on("close", (code) => {
      clearTimeout(timer);
      clearTimeout(killTimer);
      const skills = [];
      const refused = [];
      let session;
      for (const line of out.split("\n")) {
        if (!line.startsWith("{")) continue;
        let event;
        try {
          event = JSON.parse(line);
        } catch {
          continue;
        }
        session ??= event.sessionID;
        const part = event.part ?? {};
        if (event.type !== "tool_use") continue;
        if (part.tool === "skill") {
          const input = part.state?.input ?? {};
          skills.push(
            String(
              input.id ?? input.name ?? input.skill ?? JSON.stringify(input),
            ),
          );
        } else {
          refused.push(part.tool);
        }
      }
      const ok = code === 0 && session !== undefined && !spawnError;
      resolve({
        ok,
        code,
        session,
        skills,
        refused,
        error: ok
          ? undefined
          : (spawnError || err.trim() || "no session events returned").slice(
              -300,
            ),
      });
    });
  });
}

const jobs = [];
cases.forEach((c, ci) => {
  for (let t = 1; t <= trials; t++) jobs.push({ ci, t });
});
const results = cases.map(() => []);
let next = 0;
async function worker() {
  while (next < jobs.length) {
    const { ci, t } = jobs[next++];
    const r = await trial(
      cases[ci].request,
      `skill-trigger-eval ${skill} #${ci + 1}.${t}`,
    );
    results[ci].push(r);
    process.stderr.write(`${r.ok ? "." : "x"}`);
  }
}
const started = Date.now();
await Promise.all(
  Array.from({ length: Math.min(concurrency, jobs.length) }, worker),
);
process.stderr.write("\n");

let hits = 0;
let total = 0;
const rows = cases.map((c, ci) => {
  const runs = results[ci].filter((r) => r.ok);
  const loaded = runs.filter((r) => r.skills.includes(skill)).length;
  const others = [
    ...new Set(runs.flatMap((r) => r.skills).filter((s) => s !== skill)),
  ];
  // What the model reached for instead (every one refused): e.g. subagent x3
  // means it launched agents directly rather than loading the skill first.
  const tried = {};
  for (const r of runs)
    for (const tool of r.refused) tried[tool] = (tried[tool] ?? 0) + 1;
  const answeredOnly = runs.filter(
    (r) => r.skills.length === 0 && r.refused.length === 0,
  ).length;
  const correct = c.expect ? loaded : runs.length - loaded;
  hits += correct;
  total += runs.length;
  return {
    expect: c.expect ? "load" : "not load",
    request: c.request,
    loaded: `${loaded}/${runs.length}`,
    // Flag any row that was not right every time, or never ran at all.
    flagged: runs.length === 0 || correct !== runs.length,
    failedTrials: results[ci].length - runs.length,
    otherSkillsLoaded: others,
    toolsTried: tried,
    answeredWithoutTools: answeredOnly,
    loadInstead: c.loadInstead,
    sessions: results[ci].map((r) => r.session).filter(Boolean),
    errors: results[ci].filter((r) => !r.ok).map((r) => r.error),
  };
});

console.log(
  `skill ${skill}: ${trials} trial(s) per request on ${model}, ${Math.round((Date.now() - started) / 1000)}s`,
);
console.log(
  `${hits} of ${total} completed trials matched the expected first-step skill loading (not a task-correctness score)`,
);
for (const r of rows) {
  const tried = Object.entries(r.toolsTried).map(
    ([tool, n]) => `${tool} x${n}`,
  );
  console.log(
    `${r.flagged ? "!" : " "} ${r.expect.padEnd(8)} loaded ${r.loaded.padEnd(5)} ${r.request}` +
      (r.otherSkillsLoaded.length
        ? `   [other skills: ${r.otherSkillsLoaded.join(", ")}]`
        : "") +
      (tried.length ? `   [tried: ${tried.join(", ")}]` : "") +
      (r.answeredWithoutTools
        ? `   [answered without tools: ${r.answeredWithoutTools}]`
        : "") +
      (r.failedTrials ? `   (${r.failedTrials} trial(s) failed to run)` : ""),
  );
}
if (outPath) {
  writeFileSync(
    outPath,
    `${JSON.stringify({ skill, model, trials, ranAt: new Date().toISOString(), expectedOf: { hits, total }, rows }, null, 2)}\n`,
  );
  console.log(`details: ${outPath}`);
}
rmSync(sandbox, { recursive: true, force: true });
// A transport or startup failure is not a successful eval of zero trials.
if (rows.some((row) => row.failedTrials > 0)) process.exitCode = 1;

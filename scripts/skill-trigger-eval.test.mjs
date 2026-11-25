import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const runner = fileURLToPath(
  new URL("./skill-trigger-eval.mjs", import.meta.url),
);
function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), "skill-eval-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const executable = join(dir, "opencode");
  const log = join(dir, "launches.txt");
  // Oracle: hand-authored CLI events, independent of the grader. This stub
  // never runs a model or a tool. Actual permission enforcement was also
  // probed against the real CLI (touch was denied and created no file).
  writeFileSync(
    executable,
    `#!${process.execPath}
import { appendFileSync } from 'node:fs';
appendFileSync(process.env.EVAL_LAUNCH_LOG, 'launch\\n');
const request = process.argv.at(-1);
if (request === 'transport-error') { process.stderr.write('fixture transport failed'); process.exit(7); }
const sessionID = 'ses_fixture_' + process.pid;
console.log(JSON.stringify({type:'step_start',sessionID}));
if (request === 'load') console.log(JSON.stringify({type:'tool_use',sessionID,part:{tool:'skill',state:{status:'completed',input:{id:'delegate'}}}}));
if (request === 'skip') console.log(JSON.stringify({type:'tool_use',sessionID,part:{tool:'read',state:{status:'error',input:{path:'nothing'},error:'Permission denied: read'}}}));
console.log(JSON.stringify({type:'step_finish',sessionID}));
`,
  );
  chmodSync(executable, 0o755);
  const source = join(dir, "triggers.json");
  writeFileSync(
    source,
    JSON.stringify({
      skill: "delegate",
      should_load: ["load"],
      should_not_load: [{ request: "skip" }],
    }),
  );
  const run = (...args) =>
    spawnSync(process.execPath, [runner, ...args], {
      cwd: dir,
      env: {
        ...process.env,
        PATH: dir + ":" + process.env.PATH,
        EVAL_LAUNCH_LOG: log,
      },
      encoding: "utf8",
      timeout: 15_000,
    });
  return { dir, log, source, run };
}

test("strict argument validation rejects unsafe counts and unknown flags before a launch", (t) => {
  const { source, log, run } = fixture(t);
  for (const flags of [
    ["--trials", "Infinity"],
    ["--trials", "0.5"],
    ["--trials", "-1"],
    ["--concurrency", "999"],
    ["--unknown"],
    ["--model"],
  ]) {
    const r = run(source, ...flags);
    assert.equal(r.status, 2, JSON.stringify(flags) + r.stderr);
    assert.match(r.stderr, /usage:/);
  }
  assert.equal(existsSync(log), false, "invalid CLI must not invoke opencode");
});

test("known events yield four independently launched trials and the literal expected score", (t) => {
  const { dir, source, log, run } = fixture(t);
  const out = join(dir, "result.json");
  const r = run(source, "--trials", "2", "--concurrency", "2", "--out", out);
  assert.equal(r.status, 0, r.stderr);
  const result = JSON.parse(readFileSync(out, "utf8"));
  assert.deepEqual(result.expectedOf, { hits: 4, total: 4 });
  assert.deepEqual(
    result.rows.map((row) => row.loaded),
    ["2/2", "0/2"],
  );
  assert.deepEqual(result.rows[1].toolsTried, { read: 2 });
  assert.equal(new Set(result.rows.flatMap((row) => row.sessions)).size, 4);
  assert.equal(readFileSync(log, "utf8").trim().split("\n").length, 4);
});

test("failed CLI requests are failures, never a successful zero-trial eval", (t) => {
  const { dir, source, run } = fixture(t);
  writeFileSync(
    source,
    JSON.stringify({
      skill: "delegate",
      should_load: ["transport-error"],
      should_not_load: [{ request: "skip" }],
    }),
  );
  const out = join(dir, "result.json");
  const r = run(source, "--trials", "1", "--out", out);
  assert.equal(r.status, 1, r.stderr);
  const result = JSON.parse(readFileSync(out, "utf8"));
  assert.equal(result.rows[0].failedTrials, 1);
  assert.deepEqual(result.rows[0].errors, ["fixture transport failed"]);
  assert.deepEqual(result.expectedOf, { hits: 1, total: 1 });
});

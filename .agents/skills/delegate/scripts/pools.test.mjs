import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  mkdtempSync,
  mkdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { parseJsonc } from "./jsonc.mjs";

// Oracle: literal JSONC examples, and the platform JSON encoder/decoder for
// generated *string data*, not a second implementation of comment stripping.
test("JSONC removes syntax, never comment or trailing-comma lookalikes in strings", () => {
  const actual = parseJsonc(
    '/* header */ {"url":"https://example.com/a", "data":"literal,} and ,]", "a":[1,2,/* tail */], // line\n}',
  );
  assert.deepEqual(actual, {
    url: "https://example.com/a",
    data: "literal,} and ,]",
    a: [1, 2],
  });
  const fragments = [
    '"',
    "\\",
    ",}",
    ",]",
    "//",
    "/*",
    "*/",
    "\n",
    "https://example.com",
    "plain",
  ];
  for (const a of fragments) {
    for (const b of fragments) {
      const expected = { value: a + b };
      assert.deepEqual(parseJsonc(JSON.stringify(expected)), expected);
    }
  }
});

test("JSONC refuses unterminated comments and comments that join invalid tokens", () => {
  assert.throws(() => parseJsonc('{"a":1} /* unfinished'), /Unterminated/);
  assert.throws(() => parseJsonc('{"a":1/* separator */2}'), SyntaxError);
  assert.throws(() => parseJsonc('{"a":"unfinished}'), SyntaxError);
});

const here = dirname(fileURLToPath(import.meta.url));
function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), "pool-check-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  mkdirSync(join(dir, "scripts"));
  copyFileSync(join(here, "pools.mjs"), join(dir, "scripts/pools.mjs"));
  copyFileSync(join(here, "jsonc.mjs"), join(dir, "scripts/jsonc.mjs"));
  const config = {
    model: "test/leaf",
    default_agent: "build",
    providers: { "opencode-route": { models: { leaf: { hidden: true } } } },
    experimental: {
      subagent_depth: 10,
      model_routes: {
        leaf: { targets: ["test/leaf"] },
        small: { targets: ["opencode-route/leaf#low"], selection: "ordered" },
        scout: {
          targets: ["opencode-route/leaf#medium"],
          selection: "ordered",
        },
      },
    },
  };
  writeFileSync(join(dir, "config.jsonc"), JSON.stringify(config));
  // Padded cells reproduce Prettier's output; a fixed single space after
  // the route name incorrectly treated every shorter name as missing.
  writeFileSync(
    join(dir, "SKILL.md"),
    "<!-- pools:begin -->\n| `small`      | fast |\n| `scout` | lookup |\n<!-- pools:end -->\n",
  );
  const run = (...args) =>
    spawnSync(process.execPath, [join(dir, "scripts/pools.mjs"), ...args], {
      encoding: "utf8",
      cwd: dir,
    });
  return { dir, config, run };
}

// Oracle: the declared contract -- same routing is equal irrespective of
// JSON key order; an actual model/effort/visibility/depth change is not.
test("pool table accepts padded Markdown and reports a renamed pool", (t) => {
  const { dir, config, run } = fixture(t);
  let r = run("config.jsonc");
  assert.equal(r.status, 0, r.stderr + r.stdout);
  assert.match(r.stdout, /test\/leaf#low/);
  config.experimental.model_routes.scouts =
    config.experimental.model_routes.scout;
  delete config.experimental.model_routes.scout;
  writeFileSync(join(dir, "renamed.jsonc"), JSON.stringify(config));
  r = run("renamed.jsonc");
  assert.equal(r.status, 1);
  assert.match(
    r.stdout,
    /lists pools \[small, scout\].*config has \[small, scouts\]/,
  );
});

test("routing diff ignores key order but detects independent semantic changes", (t) => {
  const { dir, config, run } = fixture(t);
  writeFileSync(
    join(dir, "other.jsonc"),
    JSON.stringify({
      experimental: config.experimental,
      providers: config.providers,
      default_agent: "build",
      model: "test/leaf",
    }),
  );
  assert.equal(run("--diff", "other.jsonc", "config.jsonc").status, 0);
  for (const [label, change] of [
    [
      "model",
      (c) => {
        c.model = "test/other";
      },
    ],
    [
      "subagent_depth",
      (c) => {
        c.experimental.subagent_depth = 2;
      },
    ],
    [
      "hidden_route_models",
      (c) => {
        c.providers["opencode-route"].models.leaf.hidden = false;
      },
    ],
    [
      "model_routes.scout",
      (c) => {
        c.experimental.model_routes.scout.targets = [
          "opencode-route/leaf#high",
        ];
      },
    ],
  ]) {
    const other = structuredClone(config);
    change(other);
    writeFileSync(join(dir, "other.jsonc"), JSON.stringify(other));
    const r = run("--diff", "other.jsonc", "config.jsonc");
    assert.equal(r.status, 1, label + r.stdout + r.stderr);
    assert.ok(r.stdout.includes(label), r.stdout);
  }
});

test("empty premise and invalid command lines cannot pass silently", (t) => {
  const { dir, run } = fixture(t);
  writeFileSync(join(dir, "empty.jsonc"), "{}");
  const empty = run("--diff", "empty.jsonc", "empty.jsonc");
  assert.equal(empty.status, 1);
  assert.match(empty.stderr, /no model routes/);
  for (const args of [
    ["--diff"],
    ["--unknown"],
    ["a", "b"],
    ["--diff", "a", "--diff", "b"],
  ]) {
    const r = run(...args);
    assert.equal(r.status, 2, JSON.stringify(args));
    assert.match(r.stderr, /usage:/);
    assert.doesNotMatch(r.stderr, /ENOENT/);
  }
  assert.equal(run("--help").status, 0);
});

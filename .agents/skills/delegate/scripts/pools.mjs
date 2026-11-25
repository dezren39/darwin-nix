#!/usr/bin/env node
// Print the model pools OpenCode routes to on this machine: each pool's legs
// in failover order, the model and effort behind each leg, and the
// Artificial Analysis note the config keeps beside it ("AA 46.4 @ 4.3 min":
// Intelligence Index score, minutes per benchmark task).
//
// It reads the live config, so its output is current; the pool table in
// ../SKILL.md is only a guide. It exits 1 with a warning when that table no
// longer names the configured pools, in the configured order, so whoever
// runs it learns the skill is stale.
//
//   node pools.mjs [path/to/opencode.jsonc]
//   node pools.mjs --diff <other.jsonc> [path/to/opencode.jsonc]
//
// --diff compares the routing in two configs -- the default model and agent,
// subagent_depth, every route and pool, route tuning and the hidden route
// models -- and exits 1 when they differ. ~/.config/nix/opencode-global.jsonc
// mirrors the live config, so `--diff ~/.config/nix/opencode-global.jsonc`
// says whether that mirror is still true.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseJsonc } from "./jsonc.mjs";

const args = process.argv.slice(2);
let diffPath;
let path;
const usage =
  "usage: pools.mjs [--diff <other.jsonc>] [path/to/opencode.jsonc]";
for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (arg === "--help" && args.length === 1) {
    console.log(usage);
    process.exit(0);
  }
  if (
    arg === "--diff" &&
    diffPath === undefined &&
    args[i + 1] &&
    !args[i + 1].startsWith("-")
  ) {
    diffPath = args[++i];
  } else if (!arg.startsWith("-") && path === undefined) {
    path = arg;
  } else {
    console.error(`unexpected or incomplete argument: ${arg}\n${usage}`);
    process.exit(2);
  }
}
path ??= join(homedir(), ".config/opencode/opencode.jsonc");
const text = readFileSync(path, "utf8");
const cfg = parseJsonc(text);
if (
  !cfg.experimental?.model_routes ||
  Object.keys(cfg.experimental.model_routes).length === 0
) {
  console.error(`${path}: no model routes found; refusing an empty comparison`);
  process.exit(1);
}

if (diffPath) {
  // Key order and formatting are not routing: compare canonical JSON.
  const canonical = (v) =>
    Array.isArray(v)
      ? `[${v.map(canonical).join(",")}]`
      : v && typeof v === "object"
        ? `{${Object.keys(v)
            .sort()
            .map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`)
            .join(",")}}`
        : JSON.stringify(v);
  // v1 names the agent map "agent"; v2 names it "agents".
  const routing = (c) => ({
    model: c.model,
    default_agent: c.default_agent,
    subagent_depth: c.experimental?.subagent_depth,
    model_route_tuning: c.experimental?.model_route_tuning,
    hidden_route_models:
      c.providers?.["opencode-route"]?.models ??
      c.provider?.["opencode-route"]?.models,
    model_routes: c.experimental?.model_routes ?? {},
  });
  const other = parseJsonc(readFileSync(diffPath, "utf8"));
  const [a, b] = [routing(cfg), routing(other)];
  const differences = [];
  for (const key of Object.keys(a).filter((k) => k !== "model_routes")) {
    if (canonical(a[key]) !== canonical(b[key])) differences.push(key);
  }
  for (const name of new Set([
    ...Object.keys(a.model_routes),
    ...Object.keys(b.model_routes),
  ])) {
    if (canonical(a.model_routes[name]) !== canonical(b.model_routes[name]))
      differences.push(`model_routes.${name}`);
  }
  console.log(`routing in ${path}\n     vs ${diffPath}`);
  if (differences.length === 0) {
    console.log(
      `identical: model, default agent, subagent depth, tuning, hidden route models and all ${Object.keys(a.model_routes).length} routes`,
    );
  } else {
    console.log(`DIFFERENT (${differences.length}): ${differences.join(", ")}`);
    process.exitCode = 1;
  }
  process.exit();
}

// The note after each live leg. A commented-out leg starts with "//" and does
// not match, so disabled legs never borrow a note.
const notes = new Map();
for (const line of text.split("\n")) {
  const m = line.match(/^\s*"([^"]+)",?\s*\/\/\s*(.+?)\s*$/);
  if (m) notes.set(m[1], m[2]);
}

const routes = cfg.experimental?.model_routes ?? {};
const hidden = cfg.providers?.["opencode-route"]?.models ?? {};
const legOf = (t) =>
  typeof t === "string"
    ? t
    : `${t.model}${t.defaultVariant ? `#${t.defaultVariant}` : ""}`;
const isPool = (r) =>
  (r.targets ?? []).some((t) => legOf(t).startsWith("opencode-route/"));
const pools = Object.entries(routes).filter(([, r]) => isPool(r));
const leaves = Object.entries(routes).filter(([, r]) => !isPool(r));
const leafModel = Object.fromEntries(
  leaves.map(([name, r]) => [name, (r.targets ?? []).map(legOf).join(", ")]),
);

console.log(`config: ${path}`);
console.log(
  `default model: ${cfg.model ?? "(unset)"}    subagent depth: ${cfg.experimental?.subagent_depth ?? "(unset: OpenCode's default)"}`,
);
console.log(
  "\nPools. Call opencode-route/<pool> with no effort: each leg pins its own. Legs are tried in order.",
);
for (const [name, r] of pools) {
  console.log(`\n  ${name}${r.selection ? `  (${r.selection})` : ""}`);
  (r.targets ?? []).forEach((t, i) => {
    const leg = legOf(t);
    const [route, effort] = leg.replace(/^opencode-route\//, "").split("#");
    const model = leafModel[route]
      ? `${leafModel[route]}${effort ? `#${effort}` : ""}`
      : "";
    console.log(
      `    ${i + 1}. ${leg.padEnd(34)} ${model.padEnd(42)} ${notes.get(leg) ?? ""}`.trimEnd(),
    );
  });
}
console.log(
  "\nPer-model routes. Call opencode-route/<name>#<effort>, or the model itself as github-copilot/<id>#<effort>.",
);
for (const [name] of leaves) {
  console.log(
    `  ${name.padEnd(10)} ${leafModel[name]}${hidden[name]?.hidden ? "  (hidden from the picker, still callable)" : ""}`,
  );
}

// Guard: the skill's table must name the configured pools, in order.
const skill = join(dirname(fileURLToPath(import.meta.url)), "..", "SKILL.md");
let listed = [];
try {
  const body = readFileSync(skill, "utf8");
  const table =
    body.split("<!-- pools:begin")[1]?.split("<!-- pools:end")[0] ?? "";
  listed = [...table.matchAll(/^\|\s*`([a-z0-9-]+)`\s*\|/gm)].map((m) => m[1]);
} catch (e) {
  console.log(`\nWARNING: could not read ${skill}: ${e.message}`);
  process.exitCode = 1;
}
const configured = pools.map(([name]) => name);
if (listed.join(",") !== configured.join(",")) {
  console.log(
    `\nWARNING: ${skill} lists pools [${listed.join(", ")}] but the config has [${configured.join(", ")}]. Update the table between the pools markers.`,
  );
  process.exitCode = 1;
}

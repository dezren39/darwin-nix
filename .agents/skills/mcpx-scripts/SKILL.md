---
name: mcpx-scripts
description: "Do multi-step MCP work in one script instead of many tool calls on this machine, and save it to rerun: mcpx_exec and saved `mcpx run` scripts that combine Jira/Confluence, Datadog, Azure, Kubernetes, AWS, GitHub, browsers and code search with shell programs (gh, az, kubectl, git), and Code Mode (execute) scripts for sessions, comms, OpenChamber and GitHub. Also adding an MCP server, CLI adapter or OpenAPI service to mcpx, and fixing an MCP call that fails inside a script (a program not found on its PATH, or a 45-second wait ending in 'not confirmed'). Use when a task needs three or more tool calls or would turn several MCP calls into one step, mixes MCP and shell steps, should be saved to rerun later (a query, a report, a check), or needs a service no MCP namespace covers yet (Argo CD, say)."
---

# mcpx scripts and servers

Every MCP server on this machine runs behind the mcpx daemon; `~/.config/nix/docs/mcp.md` is the
inventory. A script calls the servers as functions and returns only what it prints, so a ten-call
process costs one turn and a few lines of context. `mcpx help agents` is mcpx's own guide; this
skill is what holds on this machine.

## Which runtime reaches what

Checked on 2026-11-24 by calling each, not by reading their descriptions:

|                       | `mcpx_exec` (OpenCode tool)                                                                                             | `mcpx exec`, `mcpx run` (shell)                          | `execute` (Code Mode)                                                                                                                                                                                                               |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language              | TypeScript on Deno                                                                                                      | TypeScript on Deno                                       | JavaScript, confined                                                                                                                                                                                                                |
| Runs where            | inside the mcpx daemon (`POST /v1/exec`): as you, in `$HOME`, with the daemon's environment                             | in your shell's directory, with your shell's environment | inside OpenCode                                                                                                                                                                                                                     |
| MCP servers           | every mcpx namespace (`Object.keys(tools)`)                                                                             | the same                                                 | only projected tools: by `mcpx_project`, or for a while after a script uses them (the catalog announces each change; `search()` shows what is there now); plus the fork's own `tools.github.*` (pulls, runs, logs, releases, `api`) |
| Sessions              | none: `tools.comms` and `tools.openchamber` are not there, whatever `mcpx_discover` and the `mcpx_exec` description say | none                                                     | `tools.comms`, `tools.opencode`, and `tools.openchamber` when OpenChamber provides it (the delegate skill says when it does not)                                                                                                    |
| Shell, files, network | `new Deno.Command`, `Deno.readTextFile`, `fetch`                                                                        | the same                                                 | `fetch` only                                                                                                                                                                                                                        |
| Saved and rerun       | no                                                                                                                      | yes, `mcpx run <name>`                                   | no                                                                                                                                                                                                                                  |

The comms row was reproduced three ways: `tools.comms.msg` and `tools.comms.sessions` are "not a
function", and `call("comms", "msg", ...)` answers `unknown server or namespace "comms"`. comms lives
in OpenCode's messaging plugin; the mcpx daemon has no comms namespace (none in its source either).
Use `execute` for anything that messages or lists sessions; to combine the two, run the `mcpx_exec`
script first and carry what it printed into the `execute` call.

The HTTP API also accepts `options.cwd` and `options.env`. Tested: setting them per request ran
in the requested worktree as the same user and found `gh` on the proposed daemon PATH, without
restarting the shared daemon. The native `mcpx_exec` tool accepts only `source`, so it cannot pass
those options; use `mcpx run` from the intended directory or an explicit `cwd` on `Deno.Command`.
`SHELL=/bin/zsh` does not start a shell: commands execute directly, without login startup files.

Three traps, all found the hard way:

- **In `mcpx_exec`, `tools.<anything>` is a function**, real or not, so `typeof` proves nothing. List
  the real namespaces with `Object.keys(tools)`, or make one real call.
- **The daemon's PATH is not your shell's.** A daemon-run script gets the launchd agent's PATH plus
  mcpx's git, deno, bun and node. Until 2026-11-24 that PATH stopped at `/usr/bin:/bin`, so `gh`,
  `az`, `kubectl` and `nix` failed to spawn, and a script that caught that error and returned `[]`
  printed "ok" for a pull request with two failing checks. `configuration.nix` now appends the
  directories a login shell searches; it takes effect at the next `just switch`. `just mcpx-exec-env`
  prints what a daemon-run script sees today. The `sh` helper below works either way.
- **A call that waits 45 seconds and then fails with "may be destructive and was not confirmed" was
  refused, not slow.** Under the default `policy.write=ask`, a tool whose server does not mark it
  read-only counts as a possible write, and nobody answers the question for a script. If the tool
  only reads, add it to that server's `readOnlyTools` in `mcpx.config.nix` (done for nixos, deepwiki
  and markitdown; measured: `nixos.nix` went from a 45 s refusal to 5.7 s). If the server itself
  refuses writes (azure's `--read-only`), `writePolicy = "allow"` on it is the alternative.

## Steps

1. **Find the tools.** `mcpx ls` (or `mcpx_discover` with no arguments), then `mcpx search <words>`,
   then `mcpx types <namespace>.<tool>` for exactly the tools you will call. One namespace's types
   cost thousands of tokens; `mcpx catalog --budget 2000` fits all of them into a budget while you are
   still choosing. Done when you have the signature of every tool you will call.
2. **Write the whole process as one script.** Independent calls run together under
   `Promise.allSettled`; filter, join and count inside the script; print the answer and the query that
   produced it. Unsure of a result's shape? Print `Object.keys(r)` or its length first. Done when one
   run returns the answer.
3. **Put shell steps in the same script**, through `sh`: the program found by absolute path, the exit
   status from the process, a failure reported as a failure. Done when a failing command shows up as
   a failure in the output.
4. **Save it if it will run again** (it ran twice, or someone will ask again):
   `~/.config/mcpx/scripts/<name>.ts` for yourself from any directory, `<repo>/.mcpx/scripts/<name>.ts`
   for a repository (commit it). The first comment line is its description in `mcpx scripts`;
   arguments arrive in `Deno.args`; `mcpx --json run <name>` returns result, logs and exit code as one
   document. `mcpx run <file>` writes `mcpx-client.ts`, `mcpx-globals.d.ts` and a
   `.<name>.<hash>.mcpx-entry.ts` beside the script; in a repository, ignore them (as
   `examples/.gitignore` does) rather than commit them. Exemplars:
   `~/.config/mcpx/scripts/opsportal-standup.ts` (Jira, GitHub and Datadog at once) and
   `examples/open-prs-with-checks.ts` beside this file (an MCP list, then `gh` per item).
   Done when `mcpx scripts` lists it and `mcpx run <name>` works.
5. **When a call fails or is slow:** `mcpx log --since 5m`, `mcpx status` (each server's stderr),
   `mcpx restart <namespace>`; for the 45-second refusal, the third trap above.

## Helpers

```ts
// GitHub and Atlassian results carry their payload under `data`.
const data = (r: any) => r?.data ?? r;

// Run a program; return stdout or throw. Looks bare names up in the system profiles,
// so it works whatever PATH the script was given.
const BIN = [
  "/run/current-system/sw/bin",
  `/etc/profiles/per-user/${Deno.env.get("USER") ?? ""}/bin`,
  "/opt/homebrew/bin",
];
async function sh(cmd: string, ...args: string[]): Promise<string> {
  let path = cmd;
  if (!cmd.includes("/")) {
    for (const dir of BIN) {
      try {
        await Deno.stat(`${dir}/${cmd}`);
        path = `${dir}/${cmd}`;
        break;
      } catch {
        /* next */
      }
    }
  }
  const out = await new Deno.Command(path, { args }).output();
  const text = new TextDecoder().decode(out.success ? out.stdout : out.stderr);
  if (!out.success)
    throw new Error(
      `${cmd} ${args.join(" ")} exited ${out.code}: ${text.trim()}`,
    );
  return text;
}
```

Checked on 2026-11-24 inside `mcpx_exec`: `sh("gh", "--version")` found gh, a failing `gh pr checks`
threw with its exit code, and a missing program threw "entity not found".

## Adding a service

1. **Look first.** `mcpx ls`, `mcpx --all-profiles ls`, `mcpx search <service>`. A CLI called through
   `sh` may be all the task needs. Done when you know nothing already covers it.
2. **Pick the form.** An MCP server: `mcpx registry search <name>`, then `mcpx registry show <name>`,
   and check nixpkgs and the vendor's own release. A CLI as typed tools: `mcpx adapter import
<program>`, generated from its completions, man page or `--help`. An HTTP API with an OpenAPI
   document: `mcpx api add <name> --spec <url>`, read-only methods unless you pass `--methods all`.
3. **Vet it like any third-party code.** Prefer the vendor's own server; read the exact command, the
   publisher and the source; pin a version; start read-only (the server's own read-only switch where
   it has one) and hide destructive tools with `excludeTools` (as `github` and `datadog` do in
   `mcpx.config.nix`). List its tools with their annotations before trusting them. Done when you can
   name its source, version and every write tool it exposes.
4. **Try it.** `mcpx servers add <name> [--env K=V] -- <command...>` is live at once, but the next
   `just switch` rewrites `~/.config/mcpx/config.json` and drops it. To try a definition exactly as
   `mcpx.config.nix` will render it, copy the config file aside, add the entry, test, and copy the
   original back.
5. **Make it permanent once it is used a lot.** In `~/.config/nix`: an entry in `mcpx.config.nix` whose
   command is an absolute `/run/current-system/sw/bin/...` path, with `env.PATH` when the server runs
   other programs (azure runs `az`; kubernetes' kubeconfig runs `kubelogin`); the package in
   `systemPackages.nix` (a prebuilt release pinned like `pkgs/azure-mcp`, or an npm-only server in
   `pkgs/npm-mcp-servers`); `readOnlyTools` or `writePolicy` as the third trap says; a row in
   `docs/mcp.md`; then `just build-no-commit`. Ask the user to run `just switch`, which needs sudo.
   Remote OAuth servers go through `mcp-remote` and `just mcp-login <name>`. A secret: the user runs
   `mcpx secrets set <NAME>`, or you ask with `openchamber_secret`; never in chat, a tool argument, a
   command line or a file.
6. **Verify.** `mcpx ls` shows it ready, one read-only call returns real data, and `just mcpx-check`
   passes. Done when all three hold.

## What is wired, and what is not yet

Added 2026-11-24 (`docs/mcp.md` has the details): **azure** (Microsoft's `azmcp` 3.0.0, read-only,
Azure CLI credentials only; needs `az login`) and **kubernetes** (containers/kubernetes-mcp-server
0.1.3, read-only, Secrets refused; the AKS API servers are private, so cluster calls need the VPN).
Neither needed the .NET SDK: both are self-contained release binaries.

Still a candidate: **Argo CD**. The registry lists `io.github.vish288/mcp-argocd` and
`io.github.asklokesh/argocd-mcp-server`, both third-party; vet carefully. The `argocd` CLI is not
installed either.

Not needed as MCP: **OpenChamber and OpenCode**. `execute` has `tools.openchamber`, `tools.opencode`
and `tools.comms`, and the `openchamber session`, `schedule` and `quota` commands take `--json`.

## Checking this skill

`evals/triggers.json` contains should-load and near-miss prompts. From darwin-nix, run
`node scripts/skill-trigger-eval.mjs .agents/skills/mcpx-scripts/evals/triggers.json --trials 3 --out <file>`.
Both saved rounds (`results-2026-11-24-1.json` and `-2.json`) include misses; the grader measures
first-step loading, not whether the requested integration or script works. The permission-restricted
trials cannot change systems. Validate actual scripts separately, as the example and the Azure/
Kubernetes artifact smoke check were validated for this change.

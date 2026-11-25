// Open pull requests with their failing checks: the github MCP namespace for
// the list, the gh CLI for each PR's checks, in one script and one turn.
//
//   mcpx run ~/.agents/skills/mcpx-scripts/examples/open-prs-with-checks.ts [owner/repo] [limit]
const [slug = "vertexinc/operations-portal", limit = "10"] = Deno.args;
if (
  Deno.args.length > 2 ||
  !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(slug) ||
  !/^\d+$/.test(limit) ||
  Number(limit) < 1 ||
  Number(limit) > 100
) {
  // GitHub's page size is at most 100. Refuse a typo instead of querying a
  // different repository or silently ignoring extra arguments.
  throw new Error(
    "usage: open-prs-with-checks.ts [owner/repo] [limit: 1..100]",
  );
}
const [owner, repo] = slug.split("/");

// GitHub and Atlassian results carry their payload under `data`.
const data = (r: any) => r?.data ?? r;

// A daemon-run script can lack the usual CLI directories on PATH, so look
// bare names up in the system profiles first. (configuration.nix adds those
// directories after a switch; this helper works before activation too.)
// The exit status comes from the process, never through a pipe, and a
// failure throws: a version of this script that caught a failed `gh` and
// returned [] printed "no failures" for a PR with two failing checks.
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
        // not in this directory; try the next
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

const prs = data(
  await tools.github.list_pull_requests({
    owner,
    repo,
    state: "open",
    perPage: Number(limit),
    fields: ["number", "title"],
  }),
);

// One gh call per PR, all at once; allSettled so one failure does not hide
// the others, and each failure is printed as a failure.
const results = await Promise.allSettled(
  prs.map(async (pr: any) => {
    const checks = JSON.parse(
      await sh(
        "gh",
        "pr",
        "checks",
        String(pr.number),
        "--repo",
        slug,
        "--json",
        "name,state",
      ),
    );
    const failing = checks
      .filter((c: any) => c.state === "FAILURE")
      .map((c: any) => c.name);
    return `#${pr.number}  ${failing.length ? `failing: ${failing.join(", ")}` : `${checks.length} checks, none failing`}  ${pr.title.slice(0, 60)}`;
  }),
);

console.log(
  `${slug}: ${prs.length} open pull requests (github MCP list_pull_requests, then gh pr checks for each)`,
);
results.forEach((r, i) => {
  console.log(
    r.status === "fulfilled"
      ? r.value
      : `#${prs[i].number}  CHECKS UNAVAILABLE: ${String(r.reason?.message ?? r.reason).split("\n")[0]}`,
  );
});

import * as vscode from "vscode";
import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";
import * as os from "os";

const DEFAULT_BACKUP_DIR = path.join(
  process.env.HOME || process.env.USERPROFILE || "/tmp",
  ".vscode-buffer-backups"
);

const META_PREFIX = "// BUFFER-BACKUP-META: ";

// Map VS Code languageId → common file extension
const LANG_TO_EXT: Record<string, string> = {
  abap: ".abap",
  bat: ".bat",
  bibtex: ".bib",
  c: ".c",
  clojure: ".clj",
  coffeescript: ".coffee",
  cpp: ".cpp",
  csharp: ".cs",
  css: ".css",
  cuda: ".cu",
  d: ".d",
  dart: ".dart",
  "dockerfile": ".dockerfile",
  elixir: ".ex",
  elm: ".elm",
  erlang: ".erl",
  fsharp: ".fs",
  "git-commit": ".txt",
  "git-rebase": ".txt",
  go: ".go",
  graphql: ".graphql",
  groovy: ".groovy",
  haml: ".haml",
  handlebars: ".hbs",
  haskell: ".hs",
  html: ".html",
  ini: ".ini",
  java: ".java",
  javascript: ".js",
  javascriptreact: ".jsx",
  json: ".json",
  jsonc: ".jsonc",
  julia: ".jl",
  kotlin: ".kt",
  latex: ".tex",
  less: ".less",
  lisp: ".lisp",
  log: ".log",
  lua: ".lua",
  makefile: ".mk",
  markdown: ".md",
  "objective-c": ".m",
  "objective-cpp": ".mm",
  ocaml: ".ml",
  pascal: ".pas",
  perl: ".pl",
  perl6: ".p6",
  php: ".php",
  plaintext: ".txt",
  powershell: ".ps1",
  pug: ".pug",
  python: ".py",
  r: ".r",
  razor: ".cshtml",
  ruby: ".rb",
  rust: ".rs",
  sass: ".sass",
  scala: ".scala",
  scheme: ".scm",
  scss: ".scss",
  shellscript: ".sh",
  slim: ".slim",
  sql: ".sql",
  stylus: ".styl",
  svelte: ".svelte",
  swift: ".swift",
  tcl: ".tcl",
  tex: ".tex",
  toml: ".toml",
  typescript: ".ts",
  typescriptreact: ".tsx",
  vb: ".vb",
  vue: ".vue",
  xml: ".xml",
  xsl: ".xsl",
  yaml: ".yaml",
  zig: ".zig",
  nix: ".nix",
  proto: ".proto",
  terraform: ".tf",
  "terraform-vars": ".tfvars",
  astro: ".astro",
  mdx: ".mdx",
  prisma: ".prisma",
  "github-actions-workflow": ".yml",
  ignore: ".gitignore",
  properties: ".properties",
  diff: ".diff",
  csv: ".csv",
  tsv: ".tsv",
  jsonl: ".jsonl",
};

function langToExtension(languageId: string): string {
  // #1721: judge the lookup by own property only. LANG_TO_EXT is a
  // plain object literal, so a bare index walks the prototype chain:
  // prototype-named languageIds (toString, constructor, __proto__,
  // hasOwnProperty, valueOf) returned inherited functions/objects
  // instead of a string, bypassing the #1649 sanitizer below and
  // landing coerced garbage in the backup filename and fileExtension
  // meta. (Object.hasOwn would do, but the ES2020 lib target predates
  // its types; hasOwnProperty.call is the same own-property test.)
  const known = Object.prototype.hasOwnProperty.call(LANG_TO_EXT, languageId)
    ? LANG_TO_EXT[languageId]
    : undefined;
  if (known) return known;
  // #1649: the fallback is spliced into the backup filename in
  // backupDoc, and a languageId is extension/user-supplied data
  // (contributed languages, files.associations), not a validated
  // identifier. Interpolating it verbatim let a separator-bearing
  // id ("a/b", "../../../evil") break out of the filename — an
  // ENOENT at write time, or a backup written outside the day
  // directory where listBackups never sees it. Sanitize it the
  // way backupDoc sanitizes the uri path.
  const safe = languageId.replace(/[^a-zA-Z0-9-]/g, "_");
  return safe ? `.${safe}` : ".txt";
}

interface Duration {
  years: number;
  months: number;
  days: number;
  hours: number;
  minutes: number;
  seconds: number;
}

function durationToSeconds(d: Duration): number {
  // Keep both maxAgeSec and cleanupAge's milliseconds/cutoff arithmetic
  // finite. At this cap (about 253,000 years), even multiplying by 1000
  // stays below JavaScript Date's representable range; larger configured
  // durations saturate and therefore do not expire real backup timestamps.
  const maxSeconds = 8_000_000_000_000;
  const components = [
    [d.years, 365 * 86400],
    [d.months, 30 * 86400],
    [d.days, 86400],
    [d.hours, 3600],
    [d.minutes, 60],
    [d.seconds, 1],
  ];
  let total = 0;
  for (const [value, secondsPerUnit] of components) {
    const safeValue = Number.isFinite(value) ? Math.max(0, value) : 0;
    if (safeValue > (maxSeconds - total) / secondsPerUnit) {
      return maxSeconds;
    }
    total += safeValue * secondsPerUnit;
  }
  return total;
}

// VS Code returns a hand-edited settings.json value verbatim even when
// it violates the package.json schema, so a numeric setting can arrive
// as a string/object and its arithmetic yields NaN -- and NaN fails
// open in the cleanup passes (#1574). Validate where settings are read:
// anything that is not a finite number falls back to the setting's
// documented default, so a Config can never carry NaN/Infinity.
function finiteNumberOr(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

// Same validate-where-read rule for the one string setting (#1580):
// backupDir's old `|| DEFAULT` guard caught only falsy values, so a
// truthy non-string (123, true, {}, ["x"]) reached fs.mkdirSync in
// activate() and threw TypeError -- the extension never started and
// no backups were taken. Anything that is not a non-empty string
// falls back to the documented default, so Config.backupDir is
// always a string.
function nonEmptyStringOr(value: unknown, fallback: string): string {
  return typeof value === "string" && value !== "" ? value : fallback;
}

function getDuration(section: string): number {
  const c = vscode.workspace.getConfiguration(section);
  // A negative component is treated as 0, its documented default
  // (#1620): finiteNumberOr alone passes negatives through, so one
  // hand-edited negative component could cancel the positive ones in
  // the sum below — days=1 with hours=-25 summed to -3600, and
  // cleanupAge reads maxAgeSec <= 0 as "disabled", so the configured
  // retention silently never ran.
  // Components are integer-declared; floor finite fractional edits as
  // well as keeping negative values at their documented 0 default.
  const component = (key: string): number =>
    Math.floor(Math.max(0, finiteNumberOr(c.get(key, 0), 0)));
  return durationToSeconds({
    years: component("years"),
    months: component("months"),
    days: component("days"),
    hours: component("hours"),
    minutes: component("minutes"),
    seconds: component("seconds"),
  });
}

function getInterval(key: string): number {
  const c = vscode.workspace.getConfiguration("bufferBackup");
  const v: unknown = c.get(key, null);
  if (typeof v !== "number" || !Number.isFinite(v) || v === 0) {
    return 5000;
  }
  // Clamp to Node's 32-bit timer ceiling (#1588): a delay above
  // 2,147,483,647 ms is clamped by Node itself to 1 ms, so a
  // ~25-day-or-longer interval would become a 1 ms cleanup loop.
  return Math.min(Math.max(1, v) * 1000, 2147483647);
}

interface Config {
  backupDir: string;
  maxAgeSec: number;
  maxTotalMb: number;
  rolloutMb: number;
  maxFileCount: number;
  rolloutFileCount: number;
  debounceMs: number;
  ageCleanupMs: number;
  sizeCleanupMs: number;
  countCleanupMs: number;
}

function getConfig(): Config {
  const c = vscode.workspace.getConfiguration("bufferBackup");
  return {
    backupDir: nonEmptyStringOr(c.get("backupDir", ""), DEFAULT_BACKUP_DIR),
    maxAgeSec: getDuration("bufferBackup.maxAge"),
    maxTotalMb: finiteNumberOr(c.get("maxTotalMb", 0), 0),
    rolloutMb: finiteNumberOr(c.get("rolloutMb", 0), 0),
    // File counts are integer-declared; don't let fractions alter the
    // cleanup threshold or count as part of a rollout.
    maxFileCount: Math.floor(finiteNumberOr(c.get("maxFileCount", 0), 0)),
    rolloutFileCount: Math.floor(finiteNumberOr(c.get("rolloutFileCount", 0), 0)),
    // Clamp to the timer-safe range [0, 2^31-1] (#1594): Node
    // collapses a negative or overflowing setTimeout delay to
    // ~1 ms, which would defeat the debounce entirely. Floor schema-
    // violating fractions to the integer milliseconds the setting declares.
    debounceMs: Math.min(Math.max(0, Math.floor(finiteNumberOr(c.get("debounceMs", 3000), 3000))), 2147483647),
    ageCleanupMs: getInterval("ageCleanupIntervalSeconds"),
    sizeCleanupMs: getInterval("sizeCleanupIntervalSeconds"),
    countCleanupMs: getInterval("countCleanupIntervalSeconds"),
  };
}

interface BackupEntry {
  name: string;
  full: string;
  mtimeMs: number;
  size: number;
}

function listBackups(dir: string): BackupEntry[] {
  if (!fs.existsSync(dir)) {
    return [];
  }
  const results: BackupEntry[] = [];
  let subs: string[];
  try {
    subs = fs.readdirSync(dir);
  } catch {
    return [];
  }
  for (const sub of subs) {
    const subFull = path.join(dir, sub);
    try {
      // lstat, not stat (#1524): a symlinked day-directory must not be
      // descended into — its target lives outside the backup dir, and
      // the cleanup passes unlink whatever listBackups returns.
      if (!fs.lstatSync(subFull).isDirectory()) {
        continue;
      }
    } catch {
      continue;
    }
    let files: string[];
    try {
      files = fs.readdirSync(subFull);
    } catch {
      continue;
    }
    for (const name of files) {
      const full = path.join(subFull, name);
      try {
        // lstat, not stat (#1524): a symlinked file is not a backup
        // entry; returning it would let cleanup delete its target.
        const st = fs.lstatSync(full);
        if (st.isFile()) {
          results.push({ name, full, mtimeMs: st.mtimeMs, size: st.size });
        }
      } catch {
        // skip files we can't stat
      }
    }
  }
  return results.sort((a, b) => a.mtimeMs - b.mtimeMs);
}

function rmEmpty(dir: string): void {
  try {
    if (
      fs.existsSync(dir) &&
      fs.statSync(dir).isDirectory() &&
      fs.readdirSync(dir).length === 0
    ) {
      fs.rmSync(dir, { recursive: false });
    }
  } catch {
    // best-effort cleanup
  }
}

function cleanupAge(cfg: Config): void {
  if (cfg.maxAgeSec <= 0) {
    return;
  }
  const cutoff = Date.now() - cfg.maxAgeSec * 1000;
  const entries = listBackups(cfg.backupDir);
  // Floor at the newest backup (#1375), mirroring the #1211 floors in
  // cleanupSize/cleanupCount: listBackups is sorted oldest first, so
  // the last entry is the newest and is never deleted here. activate()
  // runs this at startup, before the initial backup, so an absence
  // longer than maxAge would otherwise empty the store -- deleting
  // the only recovery copy of a lost untitled buffer moments before
  // any replacement backup exists. The newest backup always survives.
  for (const e of entries.slice(0, -1)) {
    if (e.mtimeMs < cutoff) {
      try {
        fs.unlinkSync(e.full);
      } catch {
        // skip
      }
      rmEmpty(path.dirname(e.full));
    }
  }
}

function cleanupSize(cfg: Config): void {
  // Defence in depth (#1574): a non-finite limit/rollout is disabled,
  // never unbounded deletion -- NaN comparisons are all false, so an
  // unguarded NaN target makes every loop guard fail open.
  if (
    !Number.isFinite(cfg.maxTotalMb) ||
    !Number.isFinite(cfg.rolloutMb) ||
    cfg.maxTotalMb <= 0
  ) {
    return;
  }
  // A finite rollout of 0 is the documented default (#1612): it means
  // zero headroom, not disabled - a limit set on its own must still
  // enforce, deleting down to exactly the limit. A negative rollout
  // is clamped to 0 (zero headroom), mirroring the negative-component
  // handling in getDuration (#1620); only the limit documents 0 as
  // disabled, and only a non-finite rollout disables the pass above.
  const rolloutMb = Math.max(0, cfg.rolloutMb);
  const entries = listBackups(cfg.backupDir);
  let total = entries.reduce((s, e) => s + e.size, 0);
  const maxB = cfg.maxTotalMb * 1024 * 1024;
  // Floor the target at the newest backup's size (#1211): with
  // rolloutMb >= maxTotalMb the raw target is <= 0, which a pass
  // can only reach by emptying the directory — it deleted every
  // backup, newest included. The newest backup always survives.
  const newestB = entries.length ? entries[entries.length - 1].size : 0;
  const targetB = Math.max(maxB - rolloutMb * 1024 * 1024, newestB);
  if (total <= maxB) {
    return;
  }
  // Iterate all but the newest entry (#1530): the arithmetic floor
  // alone does not protect the newest backup, because a failed unlink
  // (#1014 accounting) leaves the budget unchanged and the loop walks
  // one entry further — far enough to reach and delete the newest.
  // cleanupAge has always excluded it structurally via slice(0, -1).
  for (const e of entries.slice(0, -1)) {
    if (total <= targetB) {
      break;
    }
    try {
      fs.unlinkSync(e.full);
      total -= e.size;
    } catch {
      // skip: a failed unlink is not a deletion (#1014) — do not
      // deduct its size, or the budget believes a file that still
      // exists on disk is gone.
    }
    rmEmpty(path.dirname(e.full));
  }
}

function cleanupCount(cfg: Config): void {
  // Defence in depth (#1574): as in cleanupSize, a non-finite
  // limit/rollout disables the pass instead of deleting everything.
  if (
    !Number.isFinite(cfg.maxFileCount) ||
    !Number.isFinite(cfg.rolloutFileCount) ||
    cfg.maxFileCount <= 0
  ) {
    return;
  }
  // Finite rollout 0 = zero headroom, not disabled (#1612, as in
  // cleanupSize); a negative rollout clamps to 0. See cleanupSize.
  const entries = listBackups(cfg.backupDir);
  if (entries.length <= cfg.maxFileCount) {
    return;
  }
  // Mirror cleanupSize: a single pass must restore the limit, freeing
  // the rollout as headroom — delete oldest-first until at most
  // maxFileCount - rolloutFileCount remain. Deleting only
  // rolloutFileCount files per pass (the previous behaviour) left a
  // far-over-limit directory still over maxFileCount after the pass.
  // Floor the target at 1 (#1211): with rolloutFileCount >=
  // maxFileCount the raw target is 0 and the pass deleted every
  // backup, newest included. The newest backup always survives.
  const target = Math.max(cfg.maxFileCount - Math.max(0, cfg.rolloutFileCount), 1);
  let remaining = entries.length;
  // All but the newest entry, as in cleanupSize (#1530): with #1014
  // accounting a failed unlink does not decrement `remaining`, so an
  // unguarded loop that started over target walks into the newest
  // entry and deletes the backup the floor exists to protect.
  for (const e of entries.slice(0, -1)) {
    if (remaining <= target) {
      break;
    }
    try {
      fs.unlinkSync(e.full);
      remaining--;
    } catch {
      // skip: a failed unlink is not a deletion (#1014) — do not
      // decrement the count for a file that still exists on disk.
    }
    rmEmpty(path.dirname(e.full));
  }
}

function utcDayDir(base: string): string {
  const d = new Date();
  const day = d.toISOString().slice(0, 10);
  const dir = path.join(base, day);
  // lstat, not stat (#1603): a symlinked day-directory must not be
  // written through - its target lives outside the backup dir, where
  // the backup would be invisible to listBackups and every cleanup
  // pass (the read side was hardened in #1524; this is the write
  // side). lstat also sees a dangling link, which mkdirSync would
  // otherwise surface as a raw ENOENT out of backupDoc.
  //
  // Checked twice on purpose (#1709): mkdirSync({recursive: true})
  // succeeds silently when the day directory already exists, including
  // when it is now a symlink to a directory - so the pre-check alone
  // left the #1603 invariant holding only if nothing changed between
  // the two calls. Re-checking after the mkdir makes it true by
  // construction: a link swapped in during the window is refused with
  // the same named error, and backupDoc's existing containment handles
  // it exactly like the pre-planted case.
  const refuseLink = (): void => {
    throw new Error(
      `buffer-backup: refusing to write through symlinked day directory: ${dir}`
    );
  };
  const isLinkNow = (): boolean => {
    try {
      return fs.lstatSync(dir).isSymbolicLink();
    } catch {
      return false;
    }
  };
  if (isLinkNow()) {
    refuseLink();
  }
  fs.mkdirSync(dir, { recursive: true });
  if (isLinkNow()) {
    refuseLink();
  }
  return dir;
}

function contentHash(s: string): string {
  return crypto.createHash("sha256").update(s).digest("hex");
}

const lastHash = new Map<string, string>();
const lastBackupPath = new Map<string, string>();

type BackupTrigger = "change" | "focus" | "init" | "close" | "will-save" | "tab-switch";

interface BackupMeta {
  sha256: string;
  bufferUri: string;
  languageId: string;
  fileExtension: string;
  lineCount: number;
  charCount: number;
  firstLine: string;
  allTabs: string[];
  openTabs: number;
  untitledTabs: number;
  dirtyTabs: number;
  terminals: string[];
  workspace: string;
  windowTitle: string;
  appName: string;
  appHost: string;
  hostname: string;
  vscodeVersion: string;
  previousBackupPath: string | null;
  trigger: BackupTrigger;
  timestamp: string;
}

function getFirstLine(text: string): string {
  const lines = text.split("\n");
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.length > 0) {
      if (trimmed.length <= 120) return trimmed;
      // #1735: a raw slice(0, 120) can split a surrogate pair straddling
      // the cut, leaving a lone high surrogate that JSON.stringify then
      // persists into the backup meta line. Back off one code unit when
      // the cut would split a pair, so the pre-ellipsis text never ends
      // in a lone surrogate.
      let cut = 120;
      const last = trimmed.charCodeAt(cut - 1);
      if (last >= 0xd800 && last <= 0xdbff) {
        const next = trimmed.charCodeAt(cut);
        if (next >= 0xdc00 && next <= 0xdfff) cut -= 1;
      }
      return trimmed.slice(0, cut) + "...";
    }
  }
  return "";
}

function getWorkspacePath(): string {
  const folders = vscode.workspace.workspaceFolders;
  if (!folders || folders.length === 0) {
    return "(no workspace)";
  }
  return folders.map((f) => f.uri.fsPath).join("; ");
}

interface TabInfo {
  labels: string[];
  open: number;
  untitled: number;
  dirty: number;
}

function getTabInfo(): TabInfo {
  const labels: string[] = [];
  let open = 0;
  let untitled = 0;
  let dirty = 0;
  for (const group of vscode.window.tabGroups.all) {
    for (const tab of group.tabs) {
      open++;
      labels.push(tab.label);
      if (tab.isDirty) {
        dirty++;
      }
      const input = tab.input;
      if (input && typeof input === "object" && "uri" in input) {
        const uri = (input as { uri: vscode.Uri }).uri;
        if (uri.scheme === "untitled") {
          untitled++;
        }
      }
    }
  }
  return { labels, open, untitled, dirty };
}

function getTerminalNames(): string[] {
  return vscode.window.terminals.map((t) => t.name);
}

function getWindowTitle(): string {
  const folders = vscode.workspace.workspaceFolders;
  const wsName = folders && folders.length > 0
    ? folders.map((f) => f.name).join(", ")
    : "(no folder)";
  return `${wsName} — ${vscode.env.appName}`;
}

function buildMeta(
  doc: vscode.TextDocument,
  text: string,
  h: string,
  trigger: BackupTrigger
): BackupMeta {
  const tabs = getTabInfo();
  const bufferUri = doc.uri.toString();
  const ext = langToExtension(doc.languageId || "txt");
  return {
    sha256: h,
    bufferUri,
    languageId: doc.languageId || "txt",
    fileExtension: ext,
    lineCount: doc.lineCount,
    charCount: text.length,
    firstLine: getFirstLine(text),
    allTabs: tabs.labels,
    openTabs: tabs.open,
    untitledTabs: tabs.untitled,
    dirtyTabs: tabs.dirty,
    terminals: getTerminalNames(),
    workspace: getWorkspacePath(),
    windowTitle: getWindowTitle(),
    appName: vscode.env.appName,
    appHost: vscode.env.appHost,
    hostname: os.hostname(),
    vscodeVersion: vscode.version,
    previousBackupPath: lastBackupPath.get(bufferUri) || null,
    trigger,
    timestamp: new Date().toISOString(),
  };
}

function formatMetaLine(meta: BackupMeta): string {
  return META_PREFIX + JSON.stringify(meta);
}

function backupDoc(
  doc: vscode.TextDocument,
  dir: string,
  trigger: BackupTrigger
): void {
  if (doc.uri.scheme !== "untitled") {
    return;
  }
  const text = doc.getText();
  if (text.length === 0) {
    return;
  }

  const key = doc.uri.toString();
  const h = contentHash(text);

  // On close/will-save triggers, always write even if hash matches (final snapshot)
  const forceWrite = trigger === "close" || trigger === "will-save";
  if (!forceWrite && lastHash.get(key) === h) {
    return;
  }

  const name = doc.uri.path.replace(/[^a-zA-Z0-9]/g, "_") || "untitled";
  const ts = new Date().toISOString().replace(/[:.]/g, "-");
  const ext = langToExtension(doc.languageId || "txt");
  let dayDir: string;
  try {
    dayDir = utcDayDir(dir);
  } catch {
    // Contained (#1603): a symlinked day directory must not throw out
    // of backupDoc - its callers are event handlers, backupAll, and
    // activate(), and one bad day directory must not stop the other
    // documents in the same backupAll pass. The hash stays unset, so
    // a later trigger retries this document.
    return;
  }

  const meta = buildMeta(doc, text, h, trigger);
  const content = formatMetaLine(meta) + "\n" + text;

  const backupFilePath = path.join(dayDir, `${name}_${ts}${ext}`);
  try {
    fs.writeFileSync(backupFilePath, content);
  } catch (err) {
    // Contained (#1729, #1603 shape): a failed write (ENOSPC/EACCES/
    // ENAMETOOLONG) must not throw out of backupDoc - its callers are
    // event handlers and backupAll, and one failed write must not stop
    // the other documents in the same backupAll pass. The hash stays
    // unset, so a later trigger retries this document. The failure is
    // not silent: it leaves the discoverable signal #1658 requires on
    // the surface its fix chose (console.error naming the path, the
    // trigger and the underlying error).
    console.error(
      `buffer-backup: contained write failure path=${backupFilePath} trigger=${trigger} error=${err instanceof Error ? err.message : String(err)}`
    );
    return;
  }
  lastHash.set(key, h);
  lastBackupPath.set(key, backupFilePath);
}

function backupAll(cfg: Config, trigger: BackupTrigger): void {
  for (const doc of vscode.workspace.textDocuments) {
    backupDoc(doc, cfg.backupDir, trigger);
  }
}

export function activate(ctx: vscode.ExtensionContext): void {
  let cfg = getConfig();
  fs.mkdirSync(cfg.backupDir, { recursive: true });

  const timers = new Map<string, ReturnType<typeof setTimeout>>();
  const cleanupTimers: ReturnType<typeof setInterval>[] = [];

  function setupCleanupTimers(): void {
    for (const t of cleanupTimers) {
      clearInterval(t);
    }
    cleanupTimers.length = 0;
    cleanupTimers.push(setInterval(() => cleanupAge(cfg), cfg.ageCleanupMs));
    cleanupTimers.push(setInterval(() => cleanupSize(cfg), cfg.sizeCleanupMs));
    cleanupTimers.push(
      setInterval(() => cleanupCount(cfg), cfg.countCleanupMs)
    );
  }

  setupCleanupTimers();

  // Track the previously active editor so we can back it up on tab switch
  let previousEditor: vscode.TextEditor | undefined = vscode.window.activeTextEditor;

  ctx.subscriptions.push(
    // Debounced backup on text change
    vscode.workspace.onDidChangeTextDocument((e) => {
      const doc = e.document;
      if (doc.uri.scheme !== "untitled") {
        return;
      }
      const key = doc.uri.toString();
      const existing = timers.get(key);
      if (existing !== undefined) {
        clearTimeout(existing);
      }
      timers.set(
        key,
        setTimeout(() => backupDoc(doc, cfg.backupDir, "change"), cfg.debounceMs)
      );
    }),

    // Backup on window focus change
    vscode.window.onDidChangeWindowState(() => {
      backupAll(cfg, "focus");
    }),

    // Backup when switching tabs (back up the tab we just left)
    vscode.window.onDidChangeActiveTextEditor((editor) => {
      if (previousEditor && previousEditor.document.uri.scheme === "untitled") {
        backupDoc(previousEditor.document, cfg.backupDir, "tab-switch");
      }
      previousEditor = editor;
    }),

    // Backup when tab is about to close (fires for untitled docs when user dismisses save dialog)
    vscode.workspace.onDidCloseTextDocument((doc) => {
      if (doc.uri.scheme !== "untitled") {
        return;
      }
      // Flush any pending debounce timer for this doc
      const key = doc.uri.toString();
      const pending = timers.get(key);
      if (pending !== undefined) {
        clearTimeout(pending);
        timers.delete(key);
      }
      backupDoc(doc, cfg.backupDir, "close");
    }),

    // Backup when save dialog appears (willSave fires before the save-as prompt)
    vscode.workspace.onWillSaveTextDocument((e) => {
      if (e.document.uri.scheme !== "untitled") {
        return;
      }
      backupDoc(e.document, cfg.backupDir, "will-save");
    }),

    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("bufferBackup")) {
        cfg = getConfig();
        fs.mkdirSync(cfg.backupDir, { recursive: true });
        setupCleanupTimers();
      }
    }),

    {
      dispose: () => {
        for (const t of cleanupTimers) {
          clearInterval(t);
        }
        for (const t of timers.values()) {
          clearTimeout(t);
        }
      },
    }
  );

  // Run initial cleanup
  cleanupAge(cfg);
  cleanupSize(cfg);
  cleanupCount(cfg);

  // Initial backup of any already-open untitled buffers
  backupAll(cfg, "init");
}

export function deactivate(): void {
  // timers cleaned up via dispose subscription
}

// Fixture test for cleanupCount in src/extension.ts (#1002, #1014, #1211,
// #1375).
//
// Run: node pkgs/buffer-backup/cleanup-count.test.mjs
//
// cleanupCount / cleanupSize / listBackups are not exported (extension.ts
// imports vscode), so — like the probe in #1002 — this test extracts those
// functions verbatim from extension.ts, strips the handful of TS type
// annotations they use, and drives the real code against a fixture
// directory of files with staggered mtimes.
//
// Post-condition under test: after ONE cleanupCount pass over a directory
// far over maxFileCount, at most maxFileCount files remain, the oldest
// are deleted first, and cleanupSize behaviour is unchanged.
import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import assert from "node:assert";
import { fileURLToPath } from "url";

const here = path.dirname(fileURLToPath(import.meta.url));
const src = fs.readFileSync(path.join(here, "src", "extension.ts"), "utf8");

function extractFunction(name) {
  const start = src.indexOf(`function ${name}(`);
  assert.notStrictEqual(start, -1, `function ${name} not found in extension.ts`);
  const open = src.indexOf("{", start);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}") {
      depth--;
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  throw new Error(`unterminated function ${name}`);
}

function stripTypes(code) {
  return code
    .replace(/: BackupEntry\[\]/g, "")
    .replace(/: string\[\]/g, "")
    .replace(/: string/g, "")
    .replace(/: boolean/g, "")
    .replace(/: number/g, "")
    .replace(/: void/g, "")
    .replace(/: Config/g, "")
    .replace(/: Duration/g, "")
    .replace(/: unknown/g, "");
}

const factory = new Function(
  "fs",
  "path",
  `${stripTypes(extractFunction("listBackups"))}
   ${stripTypes(extractFunction("rmEmpty"))}
   ${stripTypes(extractFunction("cleanupSize"))}
   ${stripTypes(extractFunction("cleanupCount"))}
   ${stripTypes(extractFunction("cleanupAge"))}
   return { listBackups, cleanupSize, cleanupCount, cleanupAge };`,
);
const { listBackups, cleanupSize, cleanupCount, cleanupAge } = factory(fs, path);

function fixture(count, sizeBytes = 16) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "buffer-backup-test-"));
  const day = path.join(dir, "2026-01-01");
  fs.mkdirSync(day);
  const base = Date.UTC(2026, 0, 1) / 1000;
  for (let i = 0; i < count; i++) {
    const name = `f${String(i).padStart(2, "0")}.txt`;
    const full = path.join(day, name);
    fs.writeFileSync(full, "x".repeat(sizeBytes));
    fs.utimesSync(full, base + i * 10, base + i * 10);
  }
  return dir;
}

function remainingNames(dir) {
  return listBackups(dir).map((e) => e.name);
}

// 1. Far over the limit: 30 files, max 10, rollout 5 -> one pass must
//    restore the limit (mirroring cleanupSize headroom: max - rollout = 5
//    remain), deleting the oldest first so the newest survive.
{
  const dir = fixture(30);
  cleanupCount({ backupDir: dir, maxFileCount: 10, rolloutFileCount: 5 });
  const names = remainingNames(dir);
  assert.ok(names.length <= 10, `expected <=10 files after one pass, got ${names.length}`);
  assert.deepStrictEqual(names, ["f25.txt", "f26.txt", "f27.txt", "f28.txt", "f29.txt"]);
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: over-limit directory converges in one cleanupCount pass, oldest deleted first");
}

// 2. At the limit: nothing is deleted.
{
  const dir = fixture(10);
  cleanupCount({ backupDir: dir, maxFileCount: 10, rolloutFileCount: 5 });
  assert.strictEqual(remainingNames(dir).length, 10);
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: at-limit directory is untouched");
}

// 3. Just over the limit: still lands at or below maxFileCount in one pass.
{
  const dir = fixture(11);
  cleanupCount({ backupDir: dir, maxFileCount: 10, rolloutFileCount: 5 });
  const names = remainingNames(dir);
  assert.ok(names.length <= 10, `expected <=10 files, got ${names.length}`);
  assert.strictEqual(names[names.length - 1], "f10.txt", "newest file must survive");
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: just-over-limit directory converges in one pass");
}

// 4. Control: cleanupSize behaviour is unchanged (30x1024B, max 0.02MB,
//    rollout 0.01MB -> 10 files / 10240B remain after one pass).
{
  const dir = fixture(30, 1024);
  cleanupSize({ backupDir: dir, maxTotalMb: 0.02, rolloutMb: 0.01 });
  const entries = listBackups(dir);
  assert.strictEqual(entries.length, 10);
  assert.strictEqual(entries.reduce((s, e) => s + e.size, 0), 10240);
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: cleanupSize control unchanged");
}

// 5. Failed unlink, cleanupCount (#1014): the oldest file sits in a
//    read-only day directory, so unlinking it fails. It must NOT be
//    counted as deleted: the pass keeps deleting newer files until
//    the target (max - rollout = 5) is actually reached, leaving the
//    undeletable oldest plus the 4 newest deletable files. The buggy
//    accounting stopped one file early, leaving 6 files.
//    (Assumes a non-root test user: root bypasses directory write
//    permissions and could unlink from a read-only directory.)
function fixtureUndeletableOldest(count, sizeBytes = 16) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "buffer-backup-test-"));
  const base = Date.UTC(2026, 0, 1) / 1000;
  const oldDay = path.join(dir, "2026-01-01");
  fs.mkdirSync(oldDay);
  const oldest = path.join(oldDay, "f00.txt");
  fs.writeFileSync(oldest, "x".repeat(sizeBytes));
  fs.utimesSync(oldest, base, base);
  const day = path.join(dir, "2026-01-02");
  fs.mkdirSync(day);
  for (let i = 1; i < count; i++) {
    const name = `f${String(i).padStart(2, "0")}.txt`;
    const full = path.join(day, name);
    fs.writeFileSync(full, "x".repeat(sizeBytes));
    fs.utimesSync(full, base + i * 10, base + i * 10);
  }
  fs.chmodSync(oldDay, 0o555);
  return { dir, oldDay };
}

function removeFixture(dir, oldDay) {
  try { fs.chmodSync(oldDay, 0o755); } catch {}
  fs.rmSync(dir, { recursive: true, force: true });
}

{
  const { dir, oldDay } = fixtureUndeletableOldest(30);
  cleanupCount({ backupDir: dir, maxFileCount: 10, rolloutFileCount: 5 });
  const names = remainingNames(dir);
  assert.deepStrictEqual(names, ["f00.txt", "f26.txt", "f27.txt", "f28.txt", "f29.txt"]);
  removeFixture(dir, oldDay);
  console.log("pass: cleanupCount does not count a failed unlink as deleted (#1014)");
}

// 6. Failed unlink, cleanupSize (#1014): same read-only-oldest fixture
//    at 30x1024B with the scenario-4 limits (max 0.02MB, rollout
//    0.01MB). The pass must keep
//    deleting until the accounted total reaches the target, leaving
//    the undeletable oldest plus the 9 newest files (10 files /
//    10240B on disk). The buggy accounting ended the pass one file
//    early, still over the size target.
{
  const { dir, oldDay } = fixtureUndeletableOldest(30, 1024);
  cleanupSize({ backupDir: dir, maxTotalMb: 0.02, rolloutMb: 0.01 });
  const entries = listBackups(dir);
  assert.strictEqual(entries.length, 10);
  assert.strictEqual(entries[0].name, "f00.txt", "undeletable oldest must survive");
  assert.strictEqual(entries.reduce((s, e) => s + e.size, 0), 10240);
  removeFixture(dir, oldDay);
  console.log("pass: cleanupSize does not count a failed unlink as deleted (#1014)");
}

// 7. rollout == max, cleanupCount (#1211): the raw target is 0 and
//    the unguarded pass deleted all 20 files. The floored target
//    leaves exactly the newest backup.
{
  const dir = fixture(20);
  cleanupCount({ backupDir: dir, maxFileCount: 10, rolloutFileCount: 10 });
  assert.deepStrictEqual(remainingNames(dir), ["f19.txt"]);
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: cleanupCount with rollout == max leaves the newest backup (#1211)");
}

// 8. rollout > max, cleanupCount (#1211): same floor applies.
{
  const dir = fixture(20);
  cleanupCount({ backupDir: dir, maxFileCount: 10, rolloutFileCount: 25 });
  assert.deepStrictEqual(remainingNames(dir), ["f19.txt"]);
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: cleanupCount with rollout > max leaves the newest backup (#1211)");
}

// 9. rollout == max, cleanupSize (#1211): the raw target is 0 bytes;
//    the floored target (newest file's size) leaves exactly it.
{
  const dir = fixture(20, 1024);
  cleanupSize({ backupDir: dir, maxTotalMb: 0.01, rolloutMb: 0.01 });
  const entries = listBackups(dir);
  assert.strictEqual(entries.length, 1);
  assert.strictEqual(entries[0].name, "f19.txt", "newest file must survive");
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: cleanupSize with rollout == max leaves the newest backup (#1211)");
}

// 10. rollout > max, cleanupSize (#1211): the raw target is
//     negative; same floor applies.
{
  const dir = fixture(20, 1024);
  cleanupSize({ backupDir: dir, maxTotalMb: 0.01, rolloutMb: 0.05 });
  const entries = listBackups(dir);
  assert.strictEqual(entries.length, 1);
  assert.strictEqual(entries[0].name, "f19.txt", "newest file must survive");
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: cleanupSize with rollout > max leaves the newest backup (#1211)");
}

// 11. Failed unlink must not cost the newest backup, cleanupCount
//     (#1530): four 16-byte backups, the oldest in a read-only day dir
//     so its unlink fails. maxFileCount 2, rollout 1 -> target 1. The
//     #1014 accounting (a failed unlink is not a deletion) makes an
//     unguarded loop walk one entry further per failure and delete
//     f03, the newest — the pass ended at target with only the
//     undeletable oldest left. The structural newest exclusion
//     (slice(0, -1), as cleanupAge has always had) leaves f00 (failed
//     unlink) and f03 (newest) standing.
function fixtureUndeletableOldestFlat() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "buffer-backup-test-"));
  const base = Date.UTC(2026, 0, 1) / 1000;
  const oldDay = path.join(dir, "2026-01-01");
  fs.mkdirSync(oldDay);
  const f0 = path.join(oldDay, "f00.txt");
  fs.writeFileSync(f0, "x".repeat(100));
  fs.utimesSync(f0, base, base);
  const day = path.join(dir, "2026-01-02");
  fs.mkdirSync(day);
  for (let i = 1; i < 4; i++) {
    const full = path.join(day, `f0${i}.txt`);
    fs.writeFileSync(full, "x".repeat(100));
    fs.utimesSync(full, base + i * 10, base + i * 10);
  }
  fs.chmodSync(oldDay, 0o555);
  return { dir, oldDay };
}

{
  const { dir, oldDay } = fixtureUndeletableOldestFlat();
  cleanupCount({ backupDir: dir, maxFileCount: 2, rolloutFileCount: 1 });
  assert.deepStrictEqual(remainingNames(dir), ["f00.txt", "f03.txt"]);
  removeFixture(dir, oldDay);
  console.log("pass: cleanupCount failed unlink does not delete the newest backup (#1530)");
}

// 12. Failed unlink must not cost the newest backup, cleanupSize
//     (#1530): same fixture (4x100B) with a 250-byte cap and 100-byte
//     rollout -> target 150B. The unguarded loop deleted f01, f02 and
//     then the newest f03 to get under target; the guarded pass stops
//     at the slice end with f00 (failed unlink) and f03 (newest)
//     standing, still over target — over target with the newest
//     intact is the correct outcome.
{
  const { dir, oldDay } = fixtureUndeletableOldestFlat();
  cleanupSize({ backupDir: dir, maxTotalMb: 250 / (1024 * 1024), rolloutMb: 100 / (1024 * 1024) });
  assert.deepStrictEqual(remainingNames(dir), ["f00.txt", "f03.txt"]);
  removeFixture(dir, oldDay);
  console.log("pass: cleanupSize failed unlink does not delete the newest backup (#1530)");
}

// 13. All backups expired, cleanupAge (#1375): the fixture mtimes are
//     2026-01-01, so with maxAgeSec = 3600 every file is past the
//     cutoff. The unguarded pass deleted all of them; the #1211-style
//     floor leaves exactly the newest backup.
{
  const dir = fixture(5);
  cleanupAge({ backupDir: dir, maxAgeSec: 3600 });
  assert.deepStrictEqual(remainingNames(dir), ["f04.txt"]);
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: cleanupAge with every backup expired leaves the newest backup (#1375)");
}

// 14. A single expired backup, cleanupAge (#1375): the newest-backup
//     floor also protects a store with exactly one entry.
{
  const dir = fixture(1);
  cleanupAge({ backupDir: dir, maxAgeSec: 3600 });
  assert.deepStrictEqual(remainingNames(dir), ["f00.txt"]);
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: cleanupAge leaves a lone expired backup standing (#1375)");
}

// 15. Mixed ages, cleanupAge (#1375): mtimes relative to now -- two
//     expired (3h, 2h old) and one fresh (1 minute old), maxAgeSec
//     3600. Only the expired non-newest entries are deleted.
{
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "buffer-backup-test-"));
  const day = path.join(dir, "2026-01-01");
  fs.mkdirSync(day);
  const nowSec = Date.now() / 1000;
  const ages = [["old1.txt", 3 * 3600], ["old2.txt", 2 * 3600], ["fresh.txt", 60]];
  for (const [name, age] of ages) {
    const full = path.join(day, name);
    fs.writeFileSync(full, "x".repeat(16));
    fs.utimesSync(full, nowSec - age, nowSec - age);
  }
  cleanupAge({ backupDir: dir, maxAgeSec: 3600 });
  assert.deepStrictEqual(remainingNames(dir), ["fresh.txt"]);
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: cleanupAge deletes only the expired non-newest backups (#1375)");
}

// 16. Symlinked day-directory (#1524): a symlink inside the backup dir
//     pointing at a sibling directory outside it. listBackups must not
//     descend into it, and none of the three cleanup passes may delete
//     the outside files (they are old enough / numerous enough that
//     every pass would take them if they were listed).
function fixtureSymlinkedDay() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "buffer-backup-link-"));
  const dir = path.join(root, "backups");
  const outside = path.join(root, "outside");
  const day = path.join(dir, "2026-01-01");
  fs.mkdirSync(day, { recursive: true });
  fs.mkdirSync(outside);
  const base = Date.UTC(2026, 0, 1) / 1000;
  for (let i = 0; i < 3; i++) {
    const full = path.join(day, `real${i}.txt`);
    fs.writeFileSync(full, "x".repeat(1024));
    fs.utimesSync(full, base + i * 10, base + i * 10);
  }
  const outsideFiles = ["victim1.txt", "victim2.txt"].map((name, i) => {
    const full = path.join(outside, name);
    fs.writeFileSync(full, "precious");
    fs.utimesSync(full, base + i * 10, base + i * 10);
    return full;
  });
  fs.symlinkSync(outside, path.join(dir, "2020-01-01"), "dir");
  return { root, dir, outsideFiles };
}

{
  const { root, dir, outsideFiles } = fixtureSymlinkedDay();
  assert.deepStrictEqual(remainingNames(dir), ["real0.txt", "real1.txt", "real2.txt"]);
  cleanupAge({ backupDir: dir, maxAgeSec: 3600 });
  for (const f of outsideFiles) assert.ok(fs.existsSync(f), `cleanupAge deleted ${f}`);
  fs.rmSync(root, { recursive: true, force: true });
  console.log("pass: cleanupAge never follows a symlinked day-directory (#1524)");
}
{
  const { root, dir, outsideFiles } = fixtureSymlinkedDay();
  cleanupSize({ backupDir: dir, maxTotalMb: 0.001, rolloutMb: 0.0005 });
  for (const f of outsideFiles) assert.ok(fs.existsSync(f), `cleanupSize deleted ${f}`);
  assert.ok(fs.lstatSync(path.join(dir, "2020-01-01")).isSymbolicLink(), "symlink itself must remain");
  fs.rmSync(root, { recursive: true, force: true });
  console.log("pass: cleanupSize never follows a symlinked day-directory (#1524)");
}
{
  const { root, dir, outsideFiles } = fixtureSymlinkedDay();
  cleanupCount({ backupDir: dir, maxFileCount: 2, rolloutFileCount: 1 });
  for (const f of outsideFiles) assert.ok(fs.existsSync(f), `cleanupCount deleted ${f}`);
  assert.deepStrictEqual(remainingNames(dir), ["real2.txt"]);
  fs.rmSync(root, { recursive: true, force: true });
  console.log("pass: cleanupCount never follows a symlinked day-directory (#1524)");
}

// 17. Symlinked file inside a real day directory (#1524): the link is
//     not a backup entry and its outside target is never deleted.
{
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "buffer-backup-link-"));
  const dir = path.join(root, "backups");
  const day = path.join(dir, "2026-01-01");
  fs.mkdirSync(day, { recursive: true });
  const target = path.join(root, "target.txt");
  fs.writeFileSync(target, "precious");
  const base = Date.UTC(2026, 0, 1) / 1000;
  fs.utimesSync(target, base, base);
  fs.symlinkSync(target, path.join(day, "linked.txt"));
  const real = path.join(day, "real.txt");
  fs.writeFileSync(real, "x".repeat(16));
  fs.utimesSync(real, base + 10, base + 10);
  assert.deepStrictEqual(remainingNames(dir), ["real.txt"]);
  cleanupAge({ backupDir: dir, maxAgeSec: 3600 });
  assert.ok(fs.existsSync(target), "cleanupAge deleted the symlink target");
  fs.rmSync(root, { recursive: true, force: true });
  console.log("pass: symlinked files are not backup entries (#1524)");
}


// 18. Non-finite limit, cleanupSize (#1574): a NaN maxTotalMb deleted
//     every backup but the newest before the guard -- the disabled
//     check (<= 0) is false for NaN and the loop guard never breaks.
//     A non-finite limit or rollout must delete nothing.
for (const bad of [NaN, Infinity, -Infinity]) {
  const dir = fixture(10, 1024);
  cleanupSize({ backupDir: dir, maxTotalMb: bad, rolloutMb: 0.01 });
  assert.strictEqual(remainingNames(dir).length, 10, `cleanupSize deleted with maxTotalMb=${bad}`);
  fs.rmSync(dir, { recursive: true, force: true });
}
{
  const dir = fixture(10, 1024);
  cleanupSize({ backupDir: dir, maxTotalMb: 0.02, rolloutMb: NaN });
  assert.strictEqual(remainingNames(dir).length, 10, "cleanupSize deleted with rolloutMb=NaN");
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: cleanupSize with a non-finite limit/rollout deletes nothing (#1574)");
}

// 19. Non-finite limit, cleanupCount (#1574): same fail-open shape as
//     cleanupSize -- NaN maxFileCount deleted all but the newest.
for (const bad of [NaN, Infinity, -Infinity]) {
  const dir = fixture(10);
  cleanupCount({ backupDir: dir, maxFileCount: bad, rolloutFileCount: 5 });
  assert.strictEqual(remainingNames(dir).length, 10, `cleanupCount deleted with maxFileCount=${bad}`);
  fs.rmSync(dir, { recursive: true, force: true });
}
{
  const dir = fixture(10);
  cleanupCount({ backupDir: dir, maxFileCount: 10, rolloutFileCount: NaN });
  assert.strictEqual(remainingNames(dir).length, 10, "cleanupCount deleted with rolloutFileCount=NaN");
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: cleanupCount with a non-finite limit/rollout deletes nothing (#1574)");
}

// 20. Config reading validates numeric settings (#1574): getConfig /
//     getDuration / getInterval are extracted with a stub vscode whose
//     getConfiguration returns hand-edited (schema-violating) values
//     verbatim, exactly as VS Code does. Non-number / non-finite values
//     must fall back to the documented defaults, and a non-numeric
//     interval must yield 5000 ms, not NaN (setInterval(NaN) is 0 ms).
{
  let configValues = {};
  const fakeVscode = {
    workspace: {
      getConfiguration: (section) => ({
        get: (key, fallback) => {
          const full = `${section}.${key}`;
          return Object.prototype.hasOwnProperty.call(configValues, full)
            ? configValues[full]
            : fallback;
        },
      }),
    },
  };
  const configFactory = new Function(
    "vscode",
    "DEFAULT_BACKUP_DIR",
    `${stripTypes(extractFunction("finiteNumberOr"))}
     ${stripTypes(extractFunction("nonEmptyStringOr"))}
     ${stripTypes(extractFunction("durationToSeconds"))}
     ${stripTypes(extractFunction("getDuration"))}
     ${stripTypes(extractFunction("getInterval"))}
     ${stripTypes(extractFunction("getConfig"))}
     return { getConfig, getInterval, finiteNumberOr };`,
  );
  const { getConfig, getInterval } = configFactory(fakeVscode, "/tmp/fallback-dir");
  configValues = {
    "bufferBackup.maxTotalMb": "abc",
    "bufferBackup.rolloutMb": Infinity,
    "bufferBackup.maxFileCount": NaN,
    "bufferBackup.rolloutFileCount": {},
    "bufferBackup.debounceMs": "3000",
    "bufferBackup.maxAge.years": "2",
    "bufferBackup.maxAge.days": 1,
    "bufferBackup.ageCleanupIntervalSeconds": "abc",
    "bufferBackup.sizeCleanupIntervalSeconds": 0,
    "bufferBackup.countCleanupIntervalSeconds": 2,
  };
  const cfg = getConfig();
  assert.strictEqual(cfg.maxTotalMb, 0, "non-numeric maxTotalMb must fall back to 0 (disabled)");
  assert.strictEqual(cfg.rolloutMb, 0, "Infinity rolloutMb must fall back to 0");
  assert.strictEqual(cfg.maxFileCount, 0, "NaN maxFileCount must fall back to 0 (disabled)");
  assert.strictEqual(cfg.rolloutFileCount, 0, "object rolloutFileCount must fall back to 0");
  assert.strictEqual(cfg.debounceMs, 3000, "non-numeric debounceMs must fall back to 3000");
  assert.strictEqual(cfg.maxAgeSec, 86400, "non-numeric duration parts fall back to 0; 1 day remains");
  assert.strictEqual(cfg.ageCleanupMs, 5000, "non-numeric interval must yield the 5000 ms default");
  assert.strictEqual(cfg.sizeCleanupMs, 5000, "0 interval keeps the existing 5000 ms rule");
  assert.strictEqual(cfg.countCleanupMs, 2000, "a valid interval is unchanged");
  for (const [k, v] of Object.entries(cfg)) {
    if (typeof v === "number") assert.ok(Number.isFinite(v), `Config.${k} must be finite, got ${v}`);
  }
  // Integer-declared settings are still returned verbatim for finite
  // fractional values unless the read site normalizes them. The count
  // fields, debounce, and maxAge components must be integers in Config.
  // Fractional interval seconds are intentionally supported as durations
  // (the existing 1.5s pin below); conversion to milliseconds preserves
  // that behavior.
  const fractionalDir = fixture(11);
  configValues = {
    "bufferBackup.backupDir": fractionalDir,
    "bufferBackup.maxFileCount": 10.5,
    "bufferBackup.rolloutFileCount": 0.5,
    "bufferBackup.debounceMs": 3000.75,
    "bufferBackup.maxAge.days": 1.5,
    "bufferBackup.ageCleanupIntervalSeconds": 1.5,
  };
  const fractionalCfg = getConfig();
  assert.strictEqual(fractionalCfg.maxFileCount, 10, "fractional maxFileCount must floor at getConfig");
  assert.strictEqual(fractionalCfg.rolloutFileCount, 0, "fractional rolloutFileCount must floor at getConfig");
  assert.strictEqual(fractionalCfg.debounceMs, 3000, "fractional debounceMs must floor at getConfig");
  assert.strictEqual(fractionalCfg.maxAgeSec, 86400, "fractional maxAge days must floor at getDuration");
  assert.strictEqual(fractionalCfg.ageCleanupMs, 1500, "fractional interval seconds retain duration semantics");
  cleanupCount(fractionalCfg);
  assert.strictEqual(remainingNames(fractionalDir).length, 11, "fractional rollout flooring to 0 must not delete a backup");
  fs.rmSync(fractionalDir, { recursive: true, force: true });
  console.log("pass: integer-declared counts, debounce, and maxAge are floored at read time; fractional interval seconds stay supported (#1624)");
  configValues = { "bufferBackup.ageCleanupIntervalSeconds": NaN };
  assert.strictEqual(getInterval("ageCleanupIntervalSeconds"), 5000, "NaN interval must yield 5000 ms");
  console.log("pass: getConfig/getDuration/getInterval validate numeric settings (#1574)");
}


// 21. Config reading validates the backupDir string setting (#1580):
//     getConfig is extracted with the same stub vscode as block 20,
//     feeding hand-edited (schema-violating) backupDir values verbatim,
//     exactly as VS Code returns them. A truthy non-string used to pass
//     the `|| DEFAULT` guard unchanged into fs.mkdirSync in activate()
//     and throw TypeError, so the extension never started and no
//     backups were taken. Non-strings and "" must fall back to
//     DEFAULT_BACKUP_DIR; a valid string is used verbatim; and the
//     resulting backupDir must accept the mkdirSync call activate()
//     makes first.
{
  let configValues = {};
  const fakeVscode = {
    workspace: {
      getConfiguration: (section) => ({
        get: (key, fallback) => {
          const full = `${section}.${key}`;
          return Object.prototype.hasOwnProperty.call(configValues, full)
            ? configValues[full]
            : fallback;
        },
      }),
    },
  };
  const configFactory = new Function(
    "vscode",
    "DEFAULT_BACKUP_DIR",
    `${stripTypes(extractFunction("finiteNumberOr"))}
     ${stripTypes(extractFunction("nonEmptyStringOr"))}
     ${stripTypes(extractFunction("durationToSeconds"))}
     ${stripTypes(extractFunction("getDuration"))}
     ${stripTypes(extractFunction("getInterval"))}
     ${stripTypes(extractFunction("getConfig"))}
     return { getConfig };`,
  );
  const fallbackDir = path.join(os.tmpdir(), "buffer-backup-fallback-dir");
  const { getConfig } = configFactory(fakeVscode, fallbackDir);
  for (const bad of [123, true, {}, ["x"]]) {
    configValues = { "bufferBackup.backupDir": bad };
    const cfg = getConfig();
    assert.strictEqual(cfg.backupDir, fallbackDir, `non-string backupDir ${JSON.stringify(bad)} must fall back to the default`);
    assert.strictEqual(typeof cfg.backupDir, "string", "Config.backupDir must always be a string");
    fs.mkdirSync(cfg.backupDir, { recursive: true });
  }
  configValues = { "bufferBackup.backupDir": "" };
  assert.strictEqual(getConfig().backupDir, fallbackDir, "empty-string backupDir must fall back to the default");
  configValues = { "bufferBackup.backupDir": "/tmp/ok-dir" };
  assert.strictEqual(getConfig().backupDir, "/tmp/ok-dir", "a valid string backupDir is used verbatim");
  configValues = {};
  assert.strictEqual(getConfig().backupDir, fallbackDir, "an unset backupDir falls back to the default");
  fs.rmSync(fallbackDir, { recursive: true, force: true });
  console.log("pass: getConfig validates the backupDir string setting (#1580)");
}

// 22. getInterval never exceeds Node's timer ceiling (#1588, oracle:
//     the 2,147,483,647 ms 32-bit signed timer limit): a cleanup
//     interval of 2,592,000 s (30 days) used to multiply to
//     2,592,000,000 ms, which Node clamps to a 1 ms setInterval loop.
//     The extracted getInterval (same stub style as block 20) must
//     return a finite delay within the ceiling for that input.
{
  let configValues = {};
  const fakeVscode = {
    workspace: {
      getConfiguration: (section) => ({
        get: (key, fallback) => {
          const full = `${section}.${key}`;
          return Object.prototype.hasOwnProperty.call(configValues, full)
            ? configValues[full]
            : fallback;
        },
      }),
    },
  };
  const configFactory = new Function(
    "vscode",
    "DEFAULT_BACKUP_DIR",
    `${stripTypes(extractFunction("finiteNumberOr"))}
     ${stripTypes(extractFunction("nonEmptyStringOr"))}
     ${stripTypes(extractFunction("durationToSeconds"))}
     ${stripTypes(extractFunction("getDuration"))}
     ${stripTypes(extractFunction("getInterval"))}
     ${stripTypes(extractFunction("getConfig"))}
     return { getConfig, getInterval };`,
  );
  const { getConfig, getInterval } = configFactory(fakeVscode, "/tmp/fallback-dir");
  configValues = { "bufferBackup.ageCleanupIntervalSeconds": 2592000 };
  const delay = getInterval("ageCleanupIntervalSeconds");
  assert.ok(Number.isFinite(delay), `30-day interval delay must be finite, got ${delay}`);
  assert.ok(delay <= 2147483647, `30-day interval delay ${delay} exceeds Node timer ceiling 2147483647`);
  assert.strictEqual(delay, 2147483647, "30-day interval must clamp to the timer ceiling");
  assert.strictEqual(getConfig().ageCleanupMs, 2147483647, "getConfig must carry the clamped interval");
  console.log("pass: getInterval clamps a 30-day interval to the Node timer ceiling (#1588)");
}

// 23. Negative maxAge components are treated as 0 (#1620): one
//     hand-edited negative component must not cancel the positive
//     ones in getDuration's sum — days=1 with hours=-25 summed to
//     -3600, and cleanupAge reads maxAgeSec <= 0 as disabled, so the
//     configured retention silently never ran. Same extraction
//     harness and stub vscode as block 20.
{
  let configValues = {};
  const fakeVscode = {
    workspace: {
      getConfiguration: (section) => ({
        get: (key, fallback) => {
          const full = `${section}.${key}`;
          return Object.prototype.hasOwnProperty.call(configValues, full)
            ? configValues[full]
            : fallback;
        },
      }),
    },
  };
  const negFactory = new Function(
    "vscode",
    "DEFAULT_BACKUP_DIR",
    `${stripTypes(extractFunction("finiteNumberOr"))}
     ${stripTypes(extractFunction("nonEmptyStringOr"))}
     ${stripTypes(extractFunction("durationToSeconds"))}
     ${stripTypes(extractFunction("getDuration"))}
     ${stripTypes(extractFunction("getInterval"))}
     ${stripTypes(extractFunction("getConfig"))}
     return { getConfig };`,
  );
  const { getConfig } = negFactory(fakeVscode, "/tmp/fallback-dir");
  configValues = {
    "bufferBackup.maxAge.days": 1,
    "bufferBackup.maxAge.hours": -25,
  };
  assert.strictEqual(getConfig().maxAgeSec, 86400, "days=1 + hours=-25 must keep the 1-day retention");
  configValues = {
    "bufferBackup.maxAge.years": 1,
    "bufferBackup.maxAge.months": -13,
  };
  assert.strictEqual(getConfig().maxAgeSec, 31536000, "years=1 + months=-13 must keep the 1-year retention");
  configValues = { "bufferBackup.maxAge.seconds": -1 };
  assert.strictEqual(getConfig().maxAgeSec, 0, "a negative-only duration is 0 (disabled), never negative");
  configValues = { "bufferBackup.maxAge.days": 7 };
  assert.strictEqual(getConfig().maxAgeSec, 604800, "a valid positive duration is unchanged");
  console.log("pass: getDuration treats negative maxAge components as 0 (#1620)");
}


// 24. getConfig clamps debounceMs to the timer-safe range (#1594,
//     oracle: the configured delay handed to setTimeout, not
//     wall-clock timing): a negative or >2^31-1 debounceMs used to
//     reach setTimeout verbatim, where Node collapses it to ~1 ms
//     and the debounce is defeated. Out-of-range values must clamp
//     to [0, 2147483647]; in-range values (including 0 and the
//     ceiling itself) pass through unchanged.
{
  let configValues = {};
  const fakeVscode = {
    workspace: {
      getConfiguration: (section) => ({
        get: (key, fallback) => {
          const full = `${section}.${key}`;
          return Object.prototype.hasOwnProperty.call(configValues, full)
            ? configValues[full]
            : fallback;
        },
      }),
    },
  };
  const configFactory = new Function(
    "vscode",
    "DEFAULT_BACKUP_DIR",
    `${stripTypes(extractFunction("finiteNumberOr"))}
     ${stripTypes(extractFunction("nonEmptyStringOr"))}
     ${stripTypes(extractFunction("durationToSeconds"))}
     ${stripTypes(extractFunction("getDuration"))}
     ${stripTypes(extractFunction("getInterval"))}
     ${stripTypes(extractFunction("getConfig"))}
     return { getConfig };`,
  );
  const { getConfig } = configFactory(fakeVscode, "/tmp/fallback-dir");
  configValues = { "bufferBackup.debounceMs": -5000 };
  assert.strictEqual(getConfig().debounceMs, 0, "negative debounceMs must clamp to 0");
  configValues = { "bufferBackup.debounceMs": 2147483648 };
  assert.strictEqual(getConfig().debounceMs, 2147483647, "2^31 debounceMs must clamp to the timer ceiling");
  configValues = { "bufferBackup.debounceMs": 2592000000 };
  assert.strictEqual(getConfig().debounceMs, 2147483647, "30-day debounceMs must clamp to the timer ceiling");
  configValues = { "bufferBackup.debounceMs": 1500 };
  assert.strictEqual(getConfig().debounceMs, 1500, "in-range debounceMs passes through unchanged");
  configValues = { "bufferBackup.debounceMs": 0 };
  assert.strictEqual(getConfig().debounceMs, 0, "0 debounceMs passes through unchanged");
  configValues = { "bufferBackup.debounceMs": 2147483647 };
  assert.strictEqual(getConfig().debounceMs, 2147483647, "ceiling debounceMs passes through unchanged");
  console.log("pass: getConfig clamps debounceMs to the timer-safe range (#1594)");
}

// 25. Live symlinked day-directory, write side (#1603): utcDayDir must
//     refuse a day dir that is a symlink to a live outside directory -
//     writing through it would put the only backup copy outside the
//     backup dir, invisible to listBackups and every cleanup pass.
// 26. Dangling symlinked day-directory (#1603): utcDayDir must fail
//     with the same named refusal, not the raw ENOENT mkdirSync throws
//     for a dangling link.
// 27. Normal day-directory (#1603 control): utcDayDir creates a real
//     directory, a file written there is listed by listBackups.
{
  const dayDirFactory = new Function(
    "fs",
    "path",
    `${stripTypes(extractFunction("utcDayDir"))}
     return { utcDayDir };`,
  );
  const { utcDayDir } = dayDirFactory(fs, path);
  const today = new Date().toISOString().slice(0, 10);
  {
    const base = fs.mkdtempSync(path.join(os.tmpdir(), "buffer-backup-test-"));
    const outside = fs.mkdtempSync(path.join(os.tmpdir(), "buffer-backup-outside-"));
    fs.symlinkSync(outside, path.join(base, today), "dir");
    assert.throws(() => utcDayDir(base), /symlinked day directory/);
    assert.deepStrictEqual(fs.readdirSync(outside), [], "nothing may be created in the link target");
    fs.rmSync(base, { recursive: true, force: true });
    fs.rmSync(outside, { recursive: true, force: true });
    console.log("pass: utcDayDir refuses a live symlinked day directory (#1603)");
  }
  {
    const base = fs.mkdtempSync(path.join(os.tmpdir(), "buffer-backup-test-"));
    const missing = path.join(base, "no-such-target");
    fs.symlinkSync(missing, path.join(base, today), "dir");
    assert.throws(
      () => utcDayDir(base),
      (e) => /symlinked day directory/.test(e.message) && e.code !== "ENOENT",
    );
    assert.ok(!fs.existsSync(missing), "the dangling target must not be created");
    fs.rmSync(base, { recursive: true, force: true });
    console.log("pass: utcDayDir refuses a dangling symlinked day directory with a named error (#1603)");
  }
  {
    const base = fs.mkdtempSync(path.join(os.tmpdir(), "buffer-backup-test-"));
    const dir = utcDayDir(base);
    assert.strictEqual(dir, path.join(base, today));
    assert.ok(fs.lstatSync(dir).isDirectory() && !fs.lstatSync(dir).isSymbolicLink());
    fs.writeFileSync(path.join(dir, "note.txt"), "hello");
    assert.deepStrictEqual(remainingNames(base), ["note.txt"]);
    fs.rmSync(base, { recursive: true, force: true });
    console.log("pass: utcDayDir normal day directory is created and listed (#1603)");
  }
}

// 28. getInterval pins negative and fractional sub-1 intervals to the
//     documented minimum (#1629, triage decision by task 11356):
//     package.json documents every cleanup interval as
//     "null/0 = 5s, min 1s". The 5s default is only for the
//     unset/invalid cases (null, 0, non-number, non-finite - blocks
//     20/22). A finite number, however far below the minimum, is a
//     configured value and clamps UP to the documented 1s minimum,
//     exactly as an over-ceiling value clamps DOWN (block 22). So
//     -3600 and 0.5 both yield 1000 ms, not 5000 ms. Decision recorded
//     on issue #1629; no production change - this pins the existing
//     Math.max(1, v) behaviour so a future refactor cannot silently
//     change a 1-second cleanup loop into a different cadence.
{
  let configValues = {};
  const fakeVscode = {
    workspace: {
      getConfiguration: (section) => ({
        get: (key, fallback) => {
          const full = `${section}.${key}`;
          return Object.prototype.hasOwnProperty.call(configValues, full)
            ? configValues[full]
            : fallback;
        },
      }),
    },
  };
  const intervalFactory = new Function(
    "vscode",
    "DEFAULT_BACKUP_DIR",
    `${stripTypes(extractFunction("finiteNumberOr"))}
     ${stripTypes(extractFunction("nonEmptyStringOr"))}
     ${stripTypes(extractFunction("durationToSeconds"))}
     ${stripTypes(extractFunction("getDuration"))}
     ${stripTypes(extractFunction("getInterval"))}
     ${stripTypes(extractFunction("getConfig"))}
     return { getConfig, getInterval };`,
  );
  const { getConfig, getInterval } = intervalFactory(fakeVscode, "/tmp/fallback-dir");
  configValues = { "bufferBackup.ageCleanupIntervalSeconds": -3600 };
  assert.strictEqual(getInterval("ageCleanupIntervalSeconds"), 1000, "negative interval must clamp to the documented 1s minimum");
  assert.strictEqual(getConfig().ageCleanupMs, 1000, "getConfig must carry the 1s-minimum interval for a negative value");
  configValues = { "bufferBackup.ageCleanupIntervalSeconds": -5 };
  assert.strictEqual(getInterval("ageCleanupIntervalSeconds"), 1000, "a small negative interval must also clamp to 1000 ms");
  configValues = { "bufferBackup.ageCleanupIntervalSeconds": 0.5 };
  assert.strictEqual(getInterval("ageCleanupIntervalSeconds"), 1000, "fractional sub-1 interval must clamp to the documented 1s minimum");
  assert.strictEqual(getConfig().ageCleanupMs, 1000, "getConfig must carry the 1s-minimum interval for a fractional value");
  configValues = { "bufferBackup.ageCleanupIntervalSeconds": 1 };
  assert.strictEqual(getInterval("ageCleanupIntervalSeconds"), 1000, "an interval of exactly 1s is unchanged");
  configValues = { "bufferBackup.ageCleanupIntervalSeconds": 1.5 };
  assert.strictEqual(getInterval("ageCleanupIntervalSeconds"), 1500, "a fractional interval above the minimum passes through unchanged");
  console.log("pass: getInterval pins negative and fractional sub-1 intervals to the 1s minimum (#1629)");
}

// 29. Huge-but-finite maxAge component (#1627): duration conversion
//     saturates at a finite 8e12-second cap whose millisecond value is
//     still finite. That retention is effectively non-expiring for real
//     backup timestamps, so cleanupAge must leave every backup intact.
{
  let configValues = {};
  const fakeVscode = {
    workspace: {
      getConfiguration: (section) => ({
        get: (key, fallback) => {
          const full = `${section}.${key}`;
          return Object.prototype.hasOwnProperty.call(configValues, full)
            ? configValues[full]
            : fallback;
        },
      }),
    },
  };
  const configFactory = new Function(
    "vscode",
    "DEFAULT_BACKUP_DIR",
    `${stripTypes(extractFunction("finiteNumberOr"))}
     ${stripTypes(extractFunction("nonEmptyStringOr"))}
     ${stripTypes(extractFunction("durationToSeconds"))}
     ${stripTypes(extractFunction("getDuration"))}
     ${stripTypes(extractFunction("getInterval"))}
     ${stripTypes(extractFunction("getConfig"))}
     return { getConfig };`,
  );
  const { getConfig } = configFactory(fakeVscode, "/tmp/fallback-dir");
  configValues = { "bufferBackup.maxAge.years": 1e303 };
  const maxAgeSec = getConfig().maxAgeSec;
  assert.ok(Number.isFinite(maxAgeSec), `maxAgeSec must be finite, got ${maxAgeSec}`);
  assert.strictEqual(maxAgeSec, 8_000_000_000_000, "overflowing duration must saturate at the documented cap");
  assert.ok(Number.isFinite(Date.now() - maxAgeSec * 1000), "the age cutoff must remain finite");

  const dir = fixture(5);
  cleanupAge({ backupDir: dir, maxAgeSec });
  assert.deepStrictEqual(remainingNames(dir), ["f00.txt", "f01.txt", "f02.txt", "f03.txt", "f04.txt"]);
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: huge-but-finite maxAge saturates and keeps real backups (#1627)");
}

// 30. A limit set alone enforces: finite rollout 0 is zero headroom,
//     not disabled (#1612). Both rollout settings default to 0 in
//     package.json, and only the limits document 0 as disabled, so
//     the natural configuration (set only maxFileCount / maxTotalMb)
//     used to disable both passes entirely and the backup dir grew
//     unbounded. With rollout 0 a pass deletes oldest-first down to
//     exactly the limit. A negative rollout is deliberately clamped
//     to 0 (zero headroom, mirroring #1620), pinned below; a
//     non-finite rollout still disables the pass (blocks 18/19).
{
  const dir = fixture(30);
  cleanupCount({ backupDir: dir, maxFileCount: 10, rolloutFileCount: 0 });
  const names = remainingNames(dir);
  assert.strictEqual(names.length, 10, "rollout 0 count pass must converge to the limit");
  assert.strictEqual(names[0], "f20.txt", "rollout 0 count pass deletes oldest first");
  assert.strictEqual(names[names.length - 1], "f29.txt", "newest backup must survive the rollout 0 count pass");
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: cleanupCount with rollout 0 converges to the limit (#1612)");
}
{
  const dir = fixture(30, 1024);
  cleanupSize({ backupDir: dir, maxTotalMb: 0.02, rolloutMb: 0 });
  const entries = listBackups(dir);
  const total = entries.reduce((sum, e) => sum + e.size, 0);
  assert.ok(total <= 0.02 * 1024 * 1024, "rollout 0 size pass must converge to the cap");
  assert.strictEqual(entries.length, 20, "rollout 0 size pass deletes exactly to the cap (20 x 1024 B)");
  assert.strictEqual(entries[entries.length - 1].name, "f29.txt", "newest backup must survive the rollout 0 size pass");
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("pass: cleanupSize with rollout 0 converges to the limit (#1612)");
}
{
  const dir = fixture(30);
  cleanupCount({ backupDir: dir, maxFileCount: 10, rolloutFileCount: -5 });
  assert.strictEqual(remainingNames(dir).length, 10, "negative count rollout must clamp to 0 and still enforce the limit");
  fs.rmSync(dir, { recursive: true, force: true });
  const dir2 = fixture(30, 1024);
  cleanupSize({ backupDir: dir2, maxTotalMb: 0.02, rolloutMb: -0.01 });
  assert.strictEqual(listBackups(dir2).length, 20, "negative size rollout must clamp to 0 and still enforce the cap");
  fs.rmSync(dir2, { recursive: true, force: true });
  console.log("pass: negative rollout clamps to 0 for both passes (#1612)");
}

console.log("cleanup-count.test.mjs: all assertions passed");

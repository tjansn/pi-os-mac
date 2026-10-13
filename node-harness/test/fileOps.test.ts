import assert from "node:assert/strict";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { FILE_OP_ID, FILE_OP_LIMITS } from "../src/contracts/actions.js";
import {
  BINARIES, childPath, copyPlan, createPlan, defaultPathGuard, deleteAllPlan, deletePlan, failedLine, FILE_OPS, FileOpStore, identityOf, movePlan, nameProblem,
  needsOwnConfirm, parentPath, pathProblem, planProblem, planUnits, realPathProblem, renamePlan, resolveDcg, reviewCommand, reviewWithDcg, runFileOp, shellQuote,
  transferAllPlan, undoPlanOf, type FileOpLogFields, type FileOpPlan, type FileOpRunOptions, type LstatFn, type PathGuard,
} from "../src/instant/fileOps.js";

/*
 * Staged file operations and their executor (DESIGN6 §4–§5 with BUILD6): argv plans, the safety rules (§4.1, one case
 * each), dcg's review exactly as Tom's pi bridge asks it (a fake dcg written into the test's temp dir — never the real
 * one), real file operations only inside temp dirs, the staged op's TTL, single use and source identity, and
 * content-free logs. Nothing here touches a real Desktop or home folder.
 */

const POSIX = process.platform !== "win32";
const SKIP = !POSIX && "file ops run POSIX binaries (/bin/rm, /bin/cp, /bin/mv …) and a /bin/sh fake dcg: macOS and Linux only";

/** A temp root with a fake home and Desktop inside; the guard allows only that home and the temp folder. */
function sandbox() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-os-fileops-")));
  const home = join(root, "home");
  const desktop = join(home, "Desktop");
  const documents = join(home, "Documents");
  mkdirSync(desktop, { recursive: true });
  mkdirSync(documents, { recursive: true });
  const guard: PathGuard = { home, temp: [root] };
  return { root, home, desktop, documents, guard, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

type DcgMode = "allow" | "deny" | "garbage" | "exit1" | "slow" | "touch";

/**
 * An executable fake dcg in `dir`: records its stdin, arguments and working directory next to itself, then answers.
 * `touch` changes `touchPath`'s mtime first (the item changed while the dialog was open), then allows.
 */
function fakeDcg(dir: string, mode: DcgMode, touchPath = ""): { path: string; stdin: () => unknown; args: () => string[]; cwd: () => string; ran: () => boolean } {
  const path = join(dir, `fake-dcg-${mode}`);
  const answers: Record<DcgMode, string> = {
    allow: "printf '%s' '{\"dcg_verdict\":\"allow\"}'",
    deny: "printf '%s' '{\"dcg_verdict\":\"deny\",\"hookSpecificOutput\":{\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"Recursive deletion\\nwas not approved.\"}}'",
    garbage: "printf '%s' 'not json'",
    exit1: "printf '%s' '{\"dcg_verdict\":\"allow\"}'; exit 1",
    slow: "sleep 5; printf '%s' '{\"dcg_verdict\":\"allow\"}'",
    touch: `/usr/bin/touch -t 200001010000 '${touchPath}'; printf '%s' '{"dcg_verdict":"allow"}'`,
  };
  const record = (name: string) => join(dir, `${mode}-${name}`);
  writeFileSync(path, [
    "#!/bin/sh",
    `cat > '${record("stdin.json")}'`,
    `printf '%s\\n' "$@" > '${record("args.txt")}'`,
    `pwd > '${record("cwd.txt")}'`,
    answers[mode],
    "",
  ].join("\n"), { mode: 0o755 });
  return {
    path,
    stdin: () => JSON.parse(readFileSync(record("stdin.json"), "utf8")),
    args: () => readFileSync(record("args.txt"), "utf8").trim().split("\n"),
    cwd: () => readFileSync(record("cwd.txt"), "utf8").trim(),
    ran: () => existsSync(record("stdin.json")),
  };
}

const DE = { german: true } as const;
const EN = { german: false } as const;

function options(guard: PathGuard, dcg: string | null, extra: Partial<FileOpRunOptions> = {}): FileOpRunOptions & { logs: { fields: FileOpLogFields; ms: number }[] } {
  const logs: { fields: FileOpLogFields; ms: number }[] = [];
  return { dcg: () => dcg, guard, log: (fields, ms) => logs.push({ fields, ms }), logs, ...extra };
}

// ---------------------------------------------------------------- plans, quoting, names

test("plans: argv with absolute binaries, `--` always, never -f or -p; dcg reviews the same argv shell-quoted with the bare binary", () => {
  const item = { path: "/Users/fixture/Desktop/my test", isDirectory: true };
  const file = { path: "/Users/fixture/Desktop/notes.txt", isDirectory: false };
  const words = { ...DE, name: "x" };
  assert.deepEqual(deletePlan(item, "/Users/fixture/Desktop", words).argv, ["/bin/rm", "-r", "--", "/Users/fixture/Desktop/my test"]);
  assert.deepEqual(deletePlan(file, "/Users/fixture/Desktop", words).argv, ["/bin/rm", "--", "/Users/fixture/Desktop/notes.txt"]);
  assert.deepEqual(createPlan("/Users/fixture/Desktop", "Neu", true, words).argv, ["/bin/mkdir", "--", "/Users/fixture/Desktop/Neu"]);
  assert.deepEqual(createPlan("/Users/fixture/Desktop", "a.txt", false, words).argv, ["/usr/bin/touch", "--", "/Users/fixture/Desktop/a.txt"]);
  assert.deepEqual(copyPlan(item, "/Users/fixture/Documents", "my test", "/Users/fixture/Desktop", words).argv,
    ["/bin/cp", "-R", "-n", "--", "/Users/fixture/Desktop/my test", "/Users/fixture/Documents/my test"]);
  assert.deepEqual(movePlan(item, "/Users/fixture/Documents", "/Users/fixture/Desktop", words).argv,
    ["/bin/mv", "-n", "--", "/Users/fixture/Desktop/my test", "/Users/fixture/Documents/my test"]);
  assert.deepEqual(renamePlan(item, "alt", "/Users/fixture/Desktop", words).argv, ["/bin/mv", "-n", "--", "/Users/fixture/Desktop/my test", "/Users/fixture/Desktop/alt"]);
  for (const plan of [deletePlan(item, "/x", words), deletePlan(file, "/x", words), copyPlan(item, "/y", "z", "/x", words), movePlan(item, "/y", "/x", words)]) {
    assert.ok(plan.argv.includes("--"));
    assert.ok(!plan.argv.some((arg) => arg === "-f" || arg === "-p" || arg === "-rf"));
    assert.ok(plan.argv[0]!.startsWith("/"));
  }
  assert.deepEqual(Object.values(BINARIES), ["/bin/rm", "/bin/mkdir", "/usr/bin/touch", "/bin/cp", "/bin/mv"]);
  // A folder delete: dcg's own dialog confirms rm -r; a file or symlink delete needs pi-os's one Return.
  assert.equal(needsOwnConfirm(deletePlan(item, "/x", words)), false);
  assert.equal(needsOwnConfirm(deletePlan(file, "/x", words)), true);
  assert.equal(needsOwnConfirm(copyPlan(file, "/y", "z", "/x", words)), false);
  // Quoting: only when needed, POSIX single quotes.
  assert.equal(reviewCommand(["/bin/rm", "-r", "--", "/Users/tom/Desktop/test"]), "rm -r -- /Users/tom/Desktop/test");
  assert.equal(reviewCommand(["/bin/rm", "-r", "--", "/Users/tom/Desktop/my test"]), "rm -r -- '/Users/tom/Desktop/my test'");
  assert.equal(shellQuote("it's"), "'it'\\''s'");
  assert.equal(shellQuote("Präsentation.key"), "'Präsentation.key'");
  assert.equal(shellQuote("$(rm -rf ~)"), "'$(rm -rf ~)'");
  assert.equal(shellQuote(""), "''");
  assert.equal(childPath("/", "x"), "/x");
  assert.equal(parentPath("/x"), "/");
  assert.equal(parentPath("/Users/fixture/Desktop/x"), "/Users/fixture/Desktop");
});

test("new names: one path component, no leading dot, no control character, ≤ 255 UTF-8 bytes", () => {
  assert.equal(nameProblem("test-alt"), null);
  assert.equal(nameProblem("Mein Projekt 2026"), null);
  assert.equal(nameProblem("Präsentation.key"), null);
  assert.equal(nameProblem(""), "empty");
  assert.equal(nameProblem("   "), "empty");
  assert.equal(nameProblem("a/b"), "separator");
  assert.equal(nameProblem("."), "dot");
  assert.equal(nameProblem(".."), "dot");
  assert.equal(nameProblem(".hidden"), "hidden");
  assert.equal(nameProblem("a\u0000b"), "control");
  assert.equal(nameProblem("a\nb"), "control");
  assert.equal(nameProblem("ä".repeat(128)), "too_long", "256 UTF-8 bytes");
  assert.equal(nameProblem("a".repeat(255)), null);
});

// ---------------------------------------------------------------- safety (DESIGN6 §4.1)

test("safety: never the shown folder or an ancestor, home, its standard folders or Library, /, a volume root, a system root, a hidden path", () => {
  const guard: PathGuard = { home: "/Users/fixture", temp: ["/private/var/folders/ab/T"] };
  const shown = "/Users/fixture/Desktop/Projekt";
  const cases: [string, ReturnType<typeof pathProblem>][] = [
    ["/Users/fixture/Desktop/Projekt/test", null],
    ["/Users/fixture/Desktop/test", null],
    ["/Users/fixture/Documents/Archiv/test.txt", null],
    ["/Volumes/USB/test", null],
    ["/private/var/folders/ab/T/pi-os-x/test", null],
    // A Finder window on the startup disk: no direct child of "/", nothing of the apps, /opt or another user.
    ["/Applications", "top_level"],
    ["/opt", "top_level"],
    ["/cores", "top_level"],
    ["/Applications/Safari.app", "system"],
    ["/Applications/Utilities/Terminal.app", "system"],
    ["/opt/homebrew/bin/x", "system"],
    ["/Users/Shared", "other_user"],
    ["/Users/Shared/test", "other_user"],
    ["/Users/other", "other_user"],
    ["/Users/other/Desktop/test", "other_user"],
    [shown, "shown_folder"],
    // An ancestor of the shown folder reports as the shown folder; without one, Desktop is a standard folder (below).
    ["/Users/fixture/Desktop", "shown_folder"],
    ["/Users/fixture", "home"],
    ["/Users", "home"],
    ["/", "root"],
    ["/Users/fixture/Documents", "standard_folder"],
    ["/Users/fixture/Downloads", "standard_folder"],
    ["/Users/fixture/Library", "standard_folder"],
    ["/Users/fixture/Library/Preferences/x.plist", "system"],
    ["/Volumes/USB", "volume_root"],
    ["/System/Library/x", "system"],
    ["/Library/LaunchDaemons/x.plist", "system"],
    ["/usr/local/bin/x", "system"],
    ["/bin/rm", "system"],
    ["/sbin/x", "system"],
    ["/private/etc/hosts", "system"],
    ["/etc/hosts", "system"],
    ["/var/db/x", "system"],
    ["/tmp/x", "system"],
    ["/private/var/folders/ab/T", "system"],
    ["/Users/fixture/.Trash", "trash"],
    ["/Users/fixture/.Trash/test", "trash"],
    ["/Volumes/USB/.Trashes/501/x", "trash"],
    ["/Users/fixture/.config/x", "hidden"],
    ["/Users/fixture/Desktop/.secret", "hidden"],
    ["relative/path", "invalid"],
    ["/Users/fixture/Desktop/test/", "invalid"],
    ["/Users/fixture/Desktop/../Documents/x", "invalid"],
    ["/Users/fixture/Desktop/a\u0000b", "invalid"],
  ];
  for (const [path, problem] of cases) assert.equal(pathProblem(path, guard, shown), problem, path);
  // Case-insensitive as APFS compares: "/users/FIXTURE/desktop" is still the Desktop folder.
  assert.equal(pathProblem("/users/FIXTURE/desktop", guard), "standard_folder");
  // A home given with a trailing slash, or reached through a symlink (its real path), is the same home.
  for (const home of [{ home: "/Users/fixture/", temp: [] }, { home: "/Users/fixture//", temp: [] }, { home: "/home/link", realHome: "/Users/fixture", temp: [] }] as PathGuard[]) {
    const label = JSON.stringify(home);
    assert.equal(pathProblem("/Users/fixture/Desktop", home), "standard_folder", label);
    assert.equal(pathProblem("/Users/fixture/Library/Preferences/x.plist", home), "system", label);
    assert.equal(pathProblem("/Users/fixture", home), "home", label);
    assert.equal(pathProblem("/Users/fixture/Desktop/test", home), null, label);
  }
  assert.equal(pathProblem("/home/link/Documents", { home: "/home/link", realHome: "/Users/fixture", temp: [] }), "standard_folder");
  assert.deepEqual(defaultPathGuard("/nonexistent-pi-os-home///").home, "/nonexistent-pi-os-home");
  // A plan is checked on its source and its target, and never into itself.
  const words = { ...EN, name: "x" };
  assert.equal(planProblem(copyPlan({ path: "/Users/fixture/Desktop/a", isDirectory: true }, "/Users/fixture/Desktop/a/b", "a", "/Users/fixture/Desktop", words), guard), "invalid");
  assert.equal(planProblem(movePlan({ path: "/Users/fixture/Desktop/a", isDirectory: true }, "/Users/fixture/Documents", "/Users/fixture/Desktop", words), guard), null);
  assert.equal(planProblem(movePlan({ path: "/Users/fixture/Documents", isDirectory: true }, "/Users/fixture/Desktop", "/Users/fixture", words), guard), "standard_folder");
  assert.equal(planProblem(createPlan("/Users/fixture/Desktop", "Neu", true, words), guard), null);
  assert.equal(planProblem(createPlan("/Users/fixture/.Trash", "x", true, words), guard), "trash");
});

// ---------------------------------------------------------------- dcg resolution and review

test("dcg resolution: PI_OS_DCG (absolute, executable; never a fallback), then ~/.local/bin/dcg, then PATH; else none", { skip: SKIP }, () => {
  const box = sandbox();
  try {
    const bin = join(box.root, "bin");
    const local = join(box.home, ".local", "bin");
    mkdirSync(bin, { recursive: true });
    mkdirSync(local, { recursive: true });
    const onPath = join(bin, "dcg");
    writeFileSync(onPath, "#!/bin/sh\n", { mode: 0o755 });
    assert.equal(resolveDcg({ PATH: `/nonexistent:${bin}` }, box.home), onPath);
    assert.equal(resolveDcg({ PATH: "relative/bin" }, box.home), null, "relative PATH entries are skipped");
    const inLocal = join(local, "dcg");
    writeFileSync(inLocal, "#!/bin/sh\n", { mode: 0o755 });
    assert.equal(resolveDcg({ PATH: bin }, box.home), inLocal, "~/.local/bin/dcg before PATH");
    const explicit = join(box.root, "my-dcg");
    writeFileSync(explicit, "#!/bin/sh\n", { mode: 0o755 });
    assert.equal(resolveDcg({ PI_OS_DCG: explicit, PATH: bin }, box.home), explicit);
    const plain = join(box.root, "not-executable");
    writeFileSync(plain, "#!/bin/sh\n", { mode: 0o644 });
    assert.equal(resolveDcg({ PI_OS_DCG: plain, PATH: bin }, box.home), null, "an explicit choice never falls back");
    assert.equal(resolveDcg({ PI_OS_DCG: "dcg", PATH: bin }, box.home), null, "relative");
    assert.equal(resolveDcg({ PI_OS_DCG: box.root, PATH: bin }, box.home), null, "a directory");
    rmSync(inLocal);
    assert.equal(resolveDcg({}, box.home), null);
  } finally {
    box.cleanup();
  }
});

test("dcg review: the pi bridge's protocol — spawn args, cwd, stdin JSON; allow only on exit 0 + allow; deny with a one-line reason; all else fails closed", { skip: SKIP }, async () => {
  const box = sandbox();
  try {
    const allow = fakeDcg(box.root, "allow");
    assert.deepEqual(await reviewWithDcg(allow.path, "rm -r -- /x/test", box.desktop), { kind: "allow" });
    assert.deepEqual(allow.stdin(), { tool_name: "Bash", tool_input: { command: "rm -r -- /x/test" }, cwd: box.desktop, dcg_explicit_verdict: true });
    assert.deepEqual(allow.args(), ["--desktop-review", "--no-color", "--agent", "pi"]);
    assert.equal(realpathSync(allow.cwd()), realpathSync(box.desktop));
    const deny = await reviewWithDcg(fakeDcg(box.root, "deny").path, "rm -r -- /x/test", box.desktop);
    assert.deepEqual(deny, { kind: "deny", reason: "Recursive deletion was not approved." }, "one line");
    for (const mode of ["garbage", "exit1"] as const) {
      assert.deepEqual(await reviewWithDcg(fakeDcg(box.root, mode).path, "rm -- /x", box.desktop), { kind: "error" }, mode);
    }
    assert.deepEqual(await reviewWithDcg(fakeDcg(box.root, "slow").path, "rm -- /x", box.desktop, { timeoutMs: 200 }), { kind: "error" }, "timeout");
    assert.deepEqual(await reviewWithDcg(join(box.root, "missing-dcg"), "rm -- /x", box.desktop), { kind: "error" }, "spawn error");
    assert.deepEqual(await reviewWithDcg(allow.path, "rm -- /x", join(box.root, "missing-folder")), { kind: "error" }, "a missing cwd");
    const controller = new AbortController();
    const pending = reviewWithDcg(fakeDcg(box.root, "slow").path, "rm -- /x", box.desktop, { signal: controller.signal });
    controller.abort();
    assert.deepEqual(await pending, { kind: "error" }, "the host went away: dcg is killed");
    // A long reason is cut to 200 characters.
    const long = join(box.root, "long-dcg");
    writeFileSync(long, `#!/bin/sh\ncat > /dev/null\nprintf '%s' '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"${"x".repeat(400)}"}}'\n`, { mode: 0o755 });
    const cut = await reviewWithDcg(long, "rm -- /x", box.desktop);
    assert.ok(cut.kind === "deny" && cut.reason.length === FILE_OP_LIMITS.maxReason, JSON.stringify(cut));
  } finally {
    box.cleanup();
  }
});

// ---------------------------------------------------------------- running ops on real files (temp dirs only)

test("run: delete a folder, a file and a symlink (the link only); create a folder and a file; the effect is verified", { skip: SKIP }, async () => {
  const box = sandbox();
  try {
    const dcg = fakeDcg(box.root, "allow");
    const store = new FileOpStore();
    const folder = join(box.desktop, "Radfotos");
    mkdirSync(folder);
    writeFileSync(join(folder, "a.jpg"), "x");
    const file = join(box.desktop, "notes.txt");
    writeFileSync(file, "notes");
    const target = join(box.documents, "keep.txt");
    writeFileSync(target, "keep");
    const link = join(box.desktop, "link");
    symlinkSync(target, link);
    // One take each: running an op drops its take's other ops.
    const [folderOp, fileOp, linkOp, mkdirOp, touchOp] = [
      deletePlan({ path: folder, isDirectory: true }, box.desktop, { ...DE, name: "Radfotos" }),
      deletePlan({ path: file, isDirectory: false }, box.desktop, { ...EN, name: "notes.txt" }),
      deletePlan({ path: link, isDirectory: false }, box.desktop, { ...EN, name: "link" }),
      createPlan(box.desktop, "Neuer Ordner", true, { ...DE, name: "Neuer Ordner" }),
      createPlan(box.desktop, "plan.md", false, { ...EN, name: "plan.md" }),
    ].map((plan, index) => store.stage([plan], { takeId: `take-${index}`, contextId: "ctx-1" })[0]);
    const run = (opId: string) => runFileOp(store, opId, options(box.guard, dcg.path));
    assert.deepEqual(await run(folderOp!), { outcome: "done", line: "„Radfotos“ gelöscht.", verdict: "allow" });
    assert.equal(existsSync(folder), false);
    assert.equal((dcg.stdin() as { tool_input: { command: string } }).tool_input.command, `rm -r -- ${folder}`);
    assert.deepEqual(await run(fileOp!), { outcome: "done", line: "Deleted “notes.txt”.", verdict: "allow" });
    assert.equal(existsSync(file), false);
    assert.equal((await run(linkOp!)).outcome, "done");
    assert.equal(existsSync(link), false);
    assert.equal(readFileSync(target, "utf8"), "keep", "a symlink is removed as a link: its target stays");
    assert.deepEqual(await run(mkdirOp!), { outcome: "done", line: "Ordner „Neuer Ordner“ erstellt.", verdict: "allow" });
    assert.ok(lstatSync(join(box.desktop, "Neuer Ordner")).isDirectory());
    assert.deepEqual(await run(touchOp!), { outcome: "done", line: "Created file “plan.md”.", verdict: "allow" });
    assert.ok(lstatSync(join(box.desktop, "plan.md")).isFile());
  } finally {
    box.cleanup();
  }
});

test("run: copy, duplicate, move and rename never clobber — an existing target is refused before dcg is asked, and stays untouched", { skip: SKIP }, async () => {
  const box = sandbox();
  try {
    const dcg = fakeDcg(box.root, "allow");
    const store = new FileOpStore();
    const folder = join(box.desktop, "Radfotos");
    mkdirSync(folder);
    writeFileSync(join(folder, "a.jpg"), "photo");
    const item = { path: folder, isDirectory: true };
    const run = (plan: FileOpPlan) => runFileOp(store, store.stage([plan])[0]!, options(box.guard, dcg.path));

    assert.deepEqual(await run(copyPlan(item, box.documents, "Radfotos", box.desktop, { ...DE, name: "Radfotos", dest: "Dokumente" })),
      { outcome: "done", line: "„Radfotos“ nach Dokumente kopiert.", verdict: "allow" });
    assert.equal(readFileSync(join(box.documents, "Radfotos", "a.jpg"), "utf8"), "photo");
    assert.ok(existsSync(folder), "a copy keeps the source");

    // The copy exists now: copying again is refused, and the existing copy is untouched.
    writeFileSync(join(box.documents, "Radfotos", "a.jpg"), "edited");
    const again = await run(copyPlan(item, box.documents, "Radfotos", box.desktop, { ...EN, name: "Radfotos", dest: "Documents" }));
    assert.deepEqual([again.outcome, again.verdict], ["failed", "none"]);
    assert.equal(again.line, "“Radfotos” already exists there — nothing was overwritten.");
    assert.equal(readFileSync(join(box.documents, "Radfotos", "a.jpg"), "utf8"), "edited");

    assert.deepEqual(await run(copyPlan(item, box.desktop, "Radfotos Kopie", box.desktop, { ...DE, name: "Radfotos", newName: "Radfotos Kopie", duplicate: true })),
      { outcome: "done", line: "„Radfotos“ dupliziert: „Radfotos Kopie“.", verdict: "allow" });
    assert.ok(existsSync(join(box.desktop, "Radfotos Kopie", "a.jpg")));

    const archive = join(box.desktop, "Archiv");
    mkdirSync(archive);
    const moved = await run(movePlan({ path: join(box.desktop, "Radfotos Kopie"), isDirectory: true }, archive, box.desktop,
      { ...DE, name: "Radfotos Kopie", dest: "„Archiv“" }));
    assert.deepEqual(moved, { outcome: "done", line: "„Radfotos Kopie“ nach „Archiv“ verschoben.", verdict: "allow" });
    assert.ok(existsSync(join(archive, "Radfotos Kopie", "a.jpg")) && !existsSync(join(box.desktop, "Radfotos Kopie")));

    // Moving onto an existing name: refused, both untouched.
    mkdirSync(join(box.desktop, "Radfotos Kopie"));
    const clobber = await run(movePlan({ path: join(box.desktop, "Radfotos Kopie"), isDirectory: true }, archive, box.desktop, { ...EN, name: "Radfotos Kopie" }));
    assert.equal(clobber.outcome, "failed");
    assert.ok(existsSync(join(box.desktop, "Radfotos Kopie")) && existsSync(join(archive, "Radfotos Kopie", "a.jpg")));

    assert.deepEqual(await run(renamePlan(item, "Radtour", box.desktop, { ...EN, name: "Radfotos", newName: "Radtour" })),
      { outcome: "done", line: "Renamed “Radfotos” to “Radtour”.", verdict: "allow" });
    assert.ok(existsSync(join(box.desktop, "Radtour", "a.jpg")) && !existsSync(folder));

    // Create where the name is taken: refused, the folder keeps its content.
    const taken = await run(createPlan(box.desktop, "Radtour", true, { ...DE, name: "Radtour" }));
    assert.equal(taken.outcome, "failed");
    assert.ok(existsSync(join(box.desktop, "Radtour", "a.jpg")));
    const touched = join(box.desktop, "plan.md");
    writeFileSync(touched, "x");
    utimesSync(touched, 946_684_800, 946_684_800);
    assert.equal((await run(createPlan(box.desktop, "plan.md", false, { ...EN, name: "plan.md" }))).outcome, "failed");
    assert.equal(lstatSync(touched).mtimeMs, 946_684_800_000, "touch never ran on an existing file");
  } finally {
    box.cleanup();
  }
});

test("run: dcg decides — a denial keeps the item and carries its reason; garbage, a non-zero exit, a timeout or no dcg run nothing", { skip: SKIP }, async () => {
  const box = sandbox();
  try {
    const store = new FileOpStore();
    const folder = join(box.desktop, "test");
    mkdirSync(folder);
    const stage = (german = true) => store.stage([deletePlan({ path: folder, isDirectory: true }, box.desktop, { german, name: "test" })])[0]!;

    const denied = await runFileOp(store, stage(), options(box.guard, fakeDcg(box.root, "deny").path));
    assert.deepEqual(denied, { outcome: "denied", line: "dcg hat das Löschen abgelehnt: Recursive deletion was not approved.", verdict: "deny" });
    const deniedEn = await runFileOp(store, stage(false), options(box.guard, fakeDcg(box.root, "deny").path));
    assert.equal(deniedEn.line, "dcg blocked deleting “test”: Recursive deletion was not approved.");
    for (const mode of ["garbage", "exit1"] as const) {
      const result = await runFileOp(store, stage(), options(box.guard, fakeDcg(box.root, mode).path));
      assert.deepEqual([result.outcome, result.verdict], ["failed", "error"], mode);
      assert.equal(result.line, "dcg konnte den Befehl nicht prüfen – nichts ausgeführt.");
    }
    const slow = await runFileOp(store, stage(), options(box.guard, fakeDcg(box.root, "slow").path, { dcgTimeoutMs: 200 }));
    assert.deepEqual([slow.outcome, slow.verdict], ["failed", "error"]);
    const missing = await runFileOp(store, stage(), options(box.guard, null));
    assert.deepEqual(missing, { outcome: "failed", line: "Kein Befehlswächter (dcg) gefunden – nichts ausgeführt.", verdict: "none" });
    const gone = await runFileOp(store, stage(), options(box.guard, join(box.root, "no-such-dcg")));
    assert.equal(gone.outcome, "failed");
    assert.ok(existsSync(folder), "nothing ran");
  } finally {
    box.cleanup();
  }
});

test("staged ops: single use, two minutes, bound to the take; the source must not have changed (before and after dcg); off or aborted runs nothing", { skip: SKIP }, async () => {
  const box = sandbox();
  try {
    const dcg = fakeDcg(box.root, "allow");
    let now = 1_000_000;
    const store = new FileOpStore({ clock: () => now });
    const file = join(box.desktop, "test.txt");
    writeFileSync(file, "x");
    const plan = deletePlan({ path: file, isDirectory: false }, box.desktop, { ...DE, name: "test.txt" });
    /** Stages and waits until the source's identity was read (the store reads it without blocking the decision). */
    let takes = 0;
    const staged = async (p: FileOpPlan = plan): Promise<string> => {
      const takeId = `take-settled-${++takes}`;
      const [id] = store.stage([p], { takeId });
      await Promise.all(store.forTake(takeId).flatMap((op) => op.snapshots));
      return id!;
    };

    // Ids, binding, single use.
    const [opId] = store.stage([plan], { takeId: "take-7", contextId: "ctx-7" });
    assert.match(opId!, FILE_OP_ID);
    assert.deepEqual(store.forTake("take-7").map((op) => [op.opId, op.contextId]), [[opId, "ctx-7"]]);
    // Unknown ids answer in English (no take, no language to answer in).
    assert.deepEqual(await runFileOp(store, "op_unknownunknownunk", options(box.guard, dcg.path)),
      { outcome: "expired", line: "That expired — please say it again.", verdict: "none" });

    // Expired: 2 minutes and a moment later.
    now += FILE_OPS.ttlMs + 1;
    assert.deepEqual(await runFileOp(store, opId!, options(box.guard, dcg.path)), { outcome: "expired", line: "Abgelaufen – bitte noch einmal sagen.", verdict: "none" });
    assert.ok(existsSync(file));
    assert.equal(dcg.ran(), false, "dcg was never asked");

    // Single use: the second run of the same op is expired.
    const [once] = store.stage([plan]);
    assert.equal((await runFileOp(store, once!, options(box.guard, dcg.path))).outcome, "done");
    writeFileSync(file, "x");
    assert.equal((await runFileOp(store, once!, options(box.guard, dcg.path))).outcome, "expired");
    assert.ok(existsSync(file), "the file written after the run was not deleted by a replay");

    // Changed since staging (another mtime): refused, untouched.
    const changed = await staged();
    utimesSync(file, 946_684_800, 946_684_800);
    assert.deepEqual(await runFileOp(store, changed, options(box.guard, dcg.path)),
      { outcome: "expired", line: "„test.txt“ hat sich inzwischen geändert – nichts ausgeführt.", verdict: "none" });
    assert.ok(existsSync(file));

    // Replaced by another item of the same name (another inode or mtime): refused.
    const replaced = await staged();
    rmSync(file);
    writeFileSync(file, "new");
    assert.equal((await runFileOp(store, replaced, options(box.guard, dcg.path))).outcome, "expired");
    assert.equal(readFileSync(file, "utf8"), "new");

    // Gone since staging.
    const goneOp = await staged();
    rmSync(file);
    assert.deepEqual(await runFileOp(store, goneOp, options(box.guard, dcg.path)), { outcome: "expired", line: "„test.txt“ gibt es nicht mehr.", verdict: "none" });

    // Changed while dcg's dialog was open: refused after the review, nothing ran.
    writeFileSync(file, "x");
    const during = await staged();
    const touching = fakeDcg(box.root, "touch", file);
    const result = await runFileOp(store, during, options(box.guard, touching.path));
    assert.deepEqual([result.outcome, result.verdict], ["expired", "allow"]);
    assert.ok(existsSync(file));

    // A delete whose item is no longer of the staged kind (a file staged as a folder): refused.
    const kind = await staged(deletePlan({ path: file, isDirectory: true }, box.desktop, { ...EN, name: "test.txt" }));
    assert.equal((await runFileOp(store, kind, options(box.guard, dcg.path))).outcome, "expired");
    assert.ok(existsSync(file));

    // File commands switched off (no full pi session any more): nothing runs.
    const [off] = store.stage([plan]);
    assert.deepEqual(await runFileOp(store, off!, options(box.guard, dcg.path, { enabled: () => false })),
      { outcome: "failed", line: "Datei-Befehle sind aus (keine volle pi-Sitzung) – nichts ausgeführt.", verdict: "none" });
    // The host went away before the review: nothing runs.
    const controller = new AbortController();
    controller.abort();
    const [aborted] = store.stage([plan]);
    assert.equal((await runFileOp(store, aborted!, options(box.guard, dcg.path, { signal: controller.signal }))).line, "Abgebrochen – nichts ausgeführt.");
    assert.ok(existsSync(file));
  } finally {
    box.cleanup();
  }
});

test("staged ops: one identity read per source when staged (not awaited), ids unique, oldest evicted beyond the cap", async () => {
  const reads: string[] = [];
  const lstat: LstatFn = async (path) => {
    reads.push(path);
    return { dev: 1n, ino: 2n, mtimeNs: 3n, isDirectory: () => true, isFile: () => false, isSymbolicLink: () => false };
  };
  let n = 0;
  const store = new FileOpStore({ lstat, maxOps: 3, mintId: () => `op_fixture_${String(++n).padStart(8, "0")}` });
  const words = { ...EN, name: "x" };
  const item = { path: "/Users/fixture/Desktop/x", isDirectory: true };
  const ids = store.stage([
    copyPlan(item, "/Users/fixture/Documents", "x", "/Users/fixture/Desktop", words),
    copyPlan(item, "/Users/fixture/Music", "x", "/Users/fixture/Desktop", words),
    createPlan("/Users/fixture/Desktop", "y", true, words),
  ], { takeId: "t" });
  assert.deepEqual(ids, ["op_fixture_00000001", "op_fixture_00000002", "op_fixture_00000003"]);
  assert.deepEqual(reads, ["/Users/fixture/Desktop/x"], "one read for the shared source, none for create");
  for (const id of ids) assert.match(id, FILE_OP_ID);
  store.stage([createPlan("/Users/fixture/Desktop", "z", true, words)]);
  assert.equal(store.size, 3);
  assert.equal(store.claim(ids[0]!).ok, false, "evicted");
  assert.equal(store.claim(ids[1]!).ok, true);
  assert.equal(store.claim(ids[1]!).ok, false, "single use");
  assert.deepEqual(await identityOf("/x", async () => { throw Object.assign(new Error("x"), { code: "ENOENT" }); }), { ok: false, code: "gone" });
  assert.deepEqual(await identityOf("/x", async () => { throw Object.assign(new Error("x"), { code: "EPERM" }); }), { ok: false, code: "unreadable" });
});

test("safety at run time: a protected target never reaches dcg; logs are content-free (op kind, outcome, verdict, ms)", { skip: SKIP }, async () => {
  const box = sandbox();
  try {
    const dcg = fakeDcg(box.root, "allow");
    const store = new FileOpStore();
    const opts = options(box.guard, dcg.path);
    // The home folder, a standard folder and the shown folder itself, staged by hand (the lane never stages them).
    for (const plan of [
      deletePlan({ path: box.home, isDirectory: true }, box.root, { ...EN, name: "home" }),
      deletePlan({ path: box.documents, isDirectory: true }, box.home, { ...EN, name: "Documents" }),
      deletePlan({ path: box.desktop, isDirectory: true }, box.desktop, { ...EN, name: "Desktop" }),
      createPlan(join(box.home, ".Trash"), "x", true, { ...EN, name: "x" }),
    ]) {
      const result = await runFileOp(store, store.stage([plan])[0]!, opts);
      assert.deepEqual([result.outcome, result.verdict], ["failed", "none"], plan.argv.join(" "));
      assert.match(result.line, /^pi-os won't touch “/u);
    }
    assert.equal(dcg.ran(), false);
    assert.ok(existsSync(box.documents) && existsSync(box.desktop));
    const secret = join(box.desktop, "Geheim Projekt");
    mkdirSync(secret);
    const denied = await runFileOp(store, store.stage([deletePlan({ path: secret, isDirectory: true }, box.desktop, { ...DE, name: "Geheim Projekt" })])[0]!,
      options(box.guard, fakeDcg(box.root, "deny").path, { log: opts.log }));
    assert.equal(denied.outcome, "denied");
    assert.equal((await runFileOp(store, store.stage([deletePlan({ path: secret, isDirectory: true }, box.desktop, { ...DE, name: "Geheim Projekt" })])[0]!, opts)).outcome, "done");
    assert.ok(opts.logs.length >= 6);
    for (const { fields, ms } of opts.logs) {
      assert.deepEqual(Object.keys(fields).sort(), ["op", "outcome", "verdict"]);
      assert.ok(["delete", "create", "copy", "move", "rename", "unknown"].includes(fields.op));
      assert.ok(["done", "denied", "failed", "expired"].includes(fields.outcome));
      assert.ok(["allow", "deny", "error", "none"].includes(fields.verdict));
      assert.ok(Number.isFinite(ms) && ms >= 0);
    }
    const logged = JSON.stringify(opts.logs);
    for (const content of ["Geheim", "Projekt", box.root, "Recursive", "rm -r", "Desktop"]) assert.ok(!logged.includes(content), content);
  } finally {
    box.cleanup();
  }
});

// ---------------------------------------------------------------- binding, real paths, the op's time limit

test("staged ops: one op of a take runs, its take's other ops go; a newer take's final in the context drops older takes' ops; the same take's finals keep theirs", () => {
  let n = 0;
  const lstat: LstatFn = async () => ({ dev: 1n, ino: 2n, mtimeNs: 3n, isDirectory: () => true, isFile: () => false, isSymbolicLink: () => false });
  const store = new FileOpStore({ lstat, mintId: () => `op_fixture_${String(++n).padStart(8, "0")}` });
  const plan = (name: string) => deletePlan({ path: `/Users/fixture/Desktop/${name}`, isDirectory: true }, "/Users/fixture/Desktop", { ...EN, name });
  // A "which one?" list: one row runs, the other row is no longer runnable; another take's op is untouched.
  const [a, b] = store.stage([plan("a"), plan("b")], { takeId: "take-1", contextId: "ctx-1" });
  const [other] = store.stage([plan("c")], { takeId: "take-9", contextId: "ctx-9" });
  assert.equal(store.claim(a!).ok, true);
  assert.equal(store.claim(b!).ok, false, "the list's other row");
  assert.equal(store.forTake("take-9").length, 1);
  // Phase B: a voice take's second final (same take) keeps the first final's act, which the host may be running.
  const [first] = store.stage([plan("d")], { takeId: "take-2", contextId: "ctx-2" });
  store.supersede({ takeId: "take-2", contextId: "ctx-2" });
  const [second] = store.stage([plan("d")], { takeId: "take-2", contextId: "ctx-2" });
  assert.equal(store.claim(first!).ok, true, "the first final's act still runs");
  assert.equal(store.claim(second!).ok, false, "and takes the second final's op with it");
  // A newer take's final in the same context: the older take's ops go.
  const [older] = store.stage([plan("e")], { takeId: "take-3", contextId: "ctx-3" });
  const [mine] = store.stage([plan("f")], { takeId: "take-4", contextId: "ctx-3" });
  store.supersede({ takeId: "take-4", contextId: "ctx-3" });
  assert.equal(store.claim(older!).ok, false);
  assert.equal(store.claim(mine!).ok, true);
  assert.equal(store.claim(other!).ok, true, "another context's op is untouched");
  // Without both a take and a context nothing is superseded; ops staged without a take have no siblings.
  const [loose, loose2] = [store.stage([plan("g")])[0], store.stage([plan("h")])[0]];
  store.supersede({ contextId: "ctx-3" });
  store.supersede({});
  assert.equal(store.claim(loose!).ok, true);
  assert.equal(store.claim(loose2!).ok, true);
});

test("safety through real paths: a symlinked folder on the way is judged by where it leads, before dcg is asked", { skip: SKIP }, async () => {
  const guard: PathGuard = { home: "/Users/fixture", temp: [] };
  const words = { ...EN, name: "test" };
  const item = { path: "/Users/fixture/Desktop/test", isDirectory: true };
  // The seam: a Desktop folder "Link" that leads to /Applications.
  const resolve = async (path: string) => (path === "/Users/fixture/Desktop/Link" ? "/Applications" : path);
  const intoLink = movePlan(item, "/Users/fixture/Desktop/Link", "/Users/fixture/Desktop", words);
  assert.equal(planProblem(intoLink, guard), null, "by its name it is a Desktop folder");
  assert.equal(await realPathProblem(intoLink, guard, resolve), "system");
  assert.equal(await realPathProblem(movePlan(item, "/Users/fixture/Documents", "/Users/fixture/Desktop", words), guard, resolve), null);
  assert.equal(await realPathProblem(intoLink, guard, async () => { throw Object.assign(new Error("x"), { code: "EACCES" }); }), "unreadable");

  const box = sandbox();
  try {
    // On disk: Desktop/Lib leads into the home's Library. The move is refused before dcg is asked; nothing moves.
    const library = join(box.home, "Library");
    mkdirSync(library);
    symlinkSync(library, join(box.desktop, "Lib"));
    const source = join(box.desktop, "test");
    mkdirSync(source);
    const dcg = fakeDcg(box.root, "allow");
    const store = new FileOpStore();
    const plan = movePlan({ path: source, isDirectory: true }, join(box.desktop, "Lib"), box.desktop, words);
    assert.equal(planProblem(plan, box.guard), null);
    assert.deepEqual(await runFileOp(store, store.stage([plan])[0]!, options(box.guard, dcg.path)),
      { outcome: "failed", line: "pi-os won't touch “test”.", verdict: "none" });
    assert.equal(dcg.ran(), false);
    assert.ok(existsSync(source) && !existsSync(join(library, "test")));
    // The item itself may be a symlink: it is acted on as a link, its own target is not followed.
    const link = join(box.desktop, "to-library");
    symlinkSync(library, link);
    assert.equal(await realPathProblem(deletePlan({ path: link, isDirectory: false }, box.desktop, words), box.guard), null);
    // A symlinked home is the home: defaultPathGuard reads its real path once.
    const linkedHome = join(box.root, "home-link");
    symlinkSync(box.home, linkedHome);
    assert.deepEqual([defaultPathGuard(`${linkedHome}/`).home, defaultPathGuard(linkedHome).realHome], [linkedHome, box.home]);
    assert.equal(pathProblem(join(box.home, "Documents"), defaultPathGuard(linkedHome)), "standard_folder");
  } finally {
    box.cleanup();
  }
});

test("run: the op leads its own process group — the time limit stops it and what it started, and the line says it may be incomplete", { skip: SKIP }, async () => {
  const box = sandbox();
  try {
    const dcg = fakeDcg(box.root, "allow");
    const pidFile = join(box.root, "child.pid");
    // A stand-in for `mv` across volumes: it starts a child process of its own and waits for it.
    const slow = join(box.root, "slow-op");
    writeFileSync(slow, `#!/bin/sh\n/bin/sleep 30 &\necho $! > '${pidFile}'\nwait\n`, { mode: 0o755 });
    const plan: FileOpPlan = { ...createPlan(box.desktop, "Neu", true, { ...DE, name: "Neu" }), argv: [slow] };
    const store = new FileOpStore();
    const result = await runFileOp(store, store.stage([plan])[0]!, options(box.guard, dcg.path, { execTimeoutMs: 400 }));
    assert.deepEqual(result, { outcome: "failed", line: "Erstellen von „Neu“ wurde abgebrochen – möglicherweise unvollständig.", verdict: "allow" });
    const child = Number(readFileSync(pidFile, "utf8").trim());
    assert.ok(child > 1);
    let alive = true;
    for (let i = 0; i < 50 && alive; i++) {
      try {
        process.kill(child, 0);
        await new Promise((resolve) => setTimeout(resolve, 40));
      } catch {
        alive = false;
      }
    }
    assert.equal(alive, false, "the op's own child was stopped with it");
    const english = { ...plan, words: { ...EN, name: "Radfotos" }, kind: "copy" as const };
    assert.equal(failedLine(english, "killed"), "Stopped copying “Radfotos” — it may be incomplete.");
  } finally {
    box.cleanup();
  }
});

test("run budget: dcg's longest review plus the op's minimum fit the run's budget, which answers before the host stops waiting", () => {
  assert.ok(FILE_OPS.dcgTimeoutMs + FILE_OPS.minExecMs <= FILE_OPS.runBudgetMs);
  assert.ok(FILE_OPS.runBudgetMs < FILE_OP_LIMITS.hostTimeoutMs);
  assert.equal(FILE_OP_LIMITS.hostTimeoutMs, 180_000, "the host's FileOpLimits.runTimeout");
});

// ---------------------------------------------------------------- DESIGN8: several items in one op, undo

test("plans for several items (DESIGN8 B3): one rm / cp / mv argv; never an item twice, nested, or into one of them", () => {
  const guard: PathGuard = { home: "/Users/fixture", temp: [] };
  const desk = "/Users/fixture/Desktop";
  const a = { path: `${desk}/a.txt`, isDirectory: false }, b = { path: `${desk}/b.txt`, isDirectory: false }, dir = { path: `${desk}/Ordner A`, isDirectory: true };
  const files = deleteAllPlan([a, b], desk, { ...DE, name: "a.txt und b.txt" });
  assert.deepEqual(files.argv, ["/bin/rm", "--", a.path, b.path]);
  assert.equal(needsOwnConfirm(files), true, "files only: pi-os's own Return");
  const mixed = deleteAllPlan([a, dir], desk, { ...DE, name: "a.txt und Ordner A" });
  assert.deepEqual(mixed.argv, ["/bin/rm", "-r", "--", a.path, dir.path]);
  assert.equal(needsOwnConfirm(mixed), false, "a directory: dcg's dialog");
  assert.equal(reviewCommand(mixed.argv), `rm -r -- ${a.path} '${dir.path}'`);
  const copy = transferAllPlan("copy", [a, dir], "/Users/fixture/Documents", desk, { ...DE, name: "x", dest: "Dokumente" });
  assert.deepEqual(copy.argv, ["/bin/cp", "-R", "-n", "--", a.path, dir.path, "/Users/fixture/Documents"]);
  assert.deepEqual(planUnits(copy).map((unit) => unit.target), ["/Users/fixture/Documents/a.txt", "/Users/fixture/Documents/Ordner A"]);
  assert.equal(planProblem(copy, guard), null);
  assert.equal(planProblem(deleteAllPlan([a, a], desk, { ...DE, name: "x" }), guard), "invalid", "an item twice");
  assert.equal(planProblem(deleteAllPlan([dir, { path: `${dir.path}/inner`, isDirectory: false }], desk, { ...DE, name: "x" }), guard), "invalid", "nested");
  assert.equal(planProblem(transferAllPlan("move", [a, dir], dir.path, desk, { ...DE, name: "x" }), guard), "invalid", "into one of them");
  assert.equal(planProblem(deleteAllPlan([a, { path: "/Users/fixture/Documents", isDirectory: true }], desk, { ...DE, name: "x" }), guard), "standard_folder");
  assert.equal(planProblem({ ...files, entries: [] }, guard), "invalid");
});

test("run several items as one op: one dcg review of the whole command, every item checked first, every effect verified", { skip: SKIP }, async () => {
  const box = sandbox();
  try {
    const dcg = fakeDcg(box.root, "allow");
    const store = new FileOpStore();
    const run = (plan: FileOpPlan, takeId: string) => runFileOp(store, store.stage([plan], { takeId })[0]!, options(box.guard, dcg.path));
    const a = join(box.desktop, "a.txt"), b = join(box.desktop, "b.txt"), folder = join(box.desktop, "Ordner A");
    writeFileSync(a, "a");
    writeFileSync(b, "b");
    mkdirSync(folder);
    const copy = transferAllPlan("copy", [{ path: a, isDirectory: false }, { path: folder, isDirectory: true }], box.documents, box.desktop,
      { ...DE, name: "a.txt und Ordner A", dest: "Dokumente" });
    assert.deepEqual(await run(copy, "t1"), { outcome: "done", line: "„a.txt und Ordner A“ nach Dokumente kopiert.", verdict: "allow" });
    assert.equal((dcg.stdin() as { tool_input: { command: string } }).tool_input.command, `cp -R -n -- ${a} '${folder}' ${box.documents}`);
    assert.ok(existsSync(join(box.documents, "a.txt")) && lstatSync(join(box.documents, "Ordner A")).isDirectory() && existsSync(a));
    // A taken target refuses the whole op before dcg is asked: nothing moves.
    const asked = dcg.stdin();
    const move = transferAllPlan("move", [{ path: b, isDirectory: false }, { path: folder, isDirectory: true }], box.documents, box.desktop,
      { ...DE, name: "b.txt und Ordner A", dest: "Dokumente" });
    const refused = await run(move, "t2");
    assert.equal(refused.outcome, "failed");
    assert.match(refused.line, /„Ordner A“ gibt es dort schon/u);
    assert.deepEqual(dcg.stdin(), asked, "dcg was not asked again");
    assert.ok(existsSync(b) && existsSync(folder));
    // Files only: one plain rm, every one gone.
    const files = deleteAllPlan([{ path: a, isDirectory: false }, { path: b, isDirectory: false }], box.desktop, { ...DE, name: "a.txt und b.txt" });
    assert.deepEqual(await run(files, "t3"), { outcome: "done", line: "„a.txt und b.txt“ gelöscht.", verdict: "allow" });
    assert.equal(existsSync(a) || existsSync(b), false);
    // One item changed after staging: the whole op expires, nothing runs.
    writeFileSync(a, "a");
    writeFileSync(b, "b");
    const staged = store.stage([deleteAllPlan([{ path: a, isDirectory: false }, { path: b, isDirectory: false }], box.desktop, { ...DE, name: "a.txt und b.txt" })], { takeId: "t4" })[0]!;
    await Promise.all(store.forTake("t4").flatMap((op) => op.snapshots));
    utimesSync(b, new Date(2000, 0, 1), new Date(2000, 0, 1));
    assert.equal((await runFileOp(store, staged, options(box.guard, dcg.path))).outcome, "expired");
    assert.ok(existsSync(a) && existsSync(b));
  } finally {
    box.cleanup();
  }
});

test("undo (DESIGN8 C): the last done op for 3 minutes; a rename goes back, a new folder goes only while empty, a written file or a delete never", { skip: SKIP }, async () => {
  const box = sandbox();
  try {
    const dcg = fakeDcg(box.root, "allow");
    let now = 1_000_000;
    const store = new FileOpStore({ clock: () => now });
    const run = (plan: FileOpPlan, takeId: string) => runFileOp(store, store.stage([plan], { takeId })[0]!, options(box.guard, dcg.path));
    assert.equal(store.lastDone(), undefined);
    // Rename, then undo it.
    const plan = join(box.desktop, "Plan");
    mkdirSync(plan);
    assert.equal((await run(renamePlan({ path: plan, isDirectory: true }, "Plan-alt", box.desktop, { ...DE, name: "Plan", newName: "Plan-alt" }), "r1")).outcome, "done");
    const back = await undoPlanOf(store.lastDone()!, true);
    assert.ok("plan" in back);
    assert.deepEqual(back.plan.argv, ["/bin/mv", "-n", "--", join(box.desktop, "Plan-alt"), plan]);
    assert.deepEqual(await run(back.plan, "r2"), { outcome: "done", line: "„Plan-alt“ in „Plan“ umbenannt.", verdict: "allow" });
    assert.ok(existsSync(plan) && !existsSync(join(box.desktop, "Plan-alt")));
    assert.equal(store.lastDone(), undefined, "an undo is used up: a second one is never a redo");
    // A copied folder goes back only while nothing inside it changed, however deep.
    const project = join(box.desktop, "Projekt");
    mkdirSync(join(project, "sub"), { recursive: true });
    writeFileSync(join(project, "sub", "a.txt"), "a");
    const copied = copyPlan({ path: project, isDirectory: true }, box.desktop, "Projekt Kopie", box.desktop, { ...DE, name: "Projekt", newName: "Projekt Kopie", duplicate: true });
    assert.equal((await run(copied, "k1")).outcome, "done");
    const untouched = await undoPlanOf(store.lastDone()!, true);
    assert.ok("plan" in untouched);
    assert.deepEqual(untouched.plan.argv, ["/bin/rm", "-r", "--", join(box.desktop, "Projekt Kopie")]);
    writeFileSync(join(box.desktop, "Projekt Kopie", "sub", "new.txt"), "work");
    assert.deepEqual(await undoPlanOf(store.lastDone()!, true), { why: "changed" }, "work saved deep inside the copy is never deleted");
    // A new folder: rmdir, which leaves a folder that has something in it.
    assert.equal((await run(createPlan(box.desktop, "Neu", true, { ...DE, name: "Neu" }), "c1")).outcome, "done");
    const remove = await undoPlanOf(store.lastDone()!, true);
    assert.ok("plan" in remove);
    assert.deepEqual(remove.plan.argv, ["/bin/rmdir", "--", join(box.desktop, "Neu")]);
    writeFileSync(join(box.desktop, "Neu", "inside.txt"), "keep");
    assert.equal((await run(remove.plan, "c2")).outcome, "failed");
    assert.equal(readFileSync(join(box.desktop, "Neu", "inside.txt"), "utf8"), "keep");
    // A new file written to since: not undone.
    assert.equal((await run(createPlan(box.desktop, "notes.md", false, { ...DE, name: "notes.md" }), "f1")).outcome, "done");
    utimesSync(join(box.desktop, "notes.md"), new Date(2001, 0, 1), new Date(2001, 0, 1));
    assert.deepEqual(await undoPlanOf(store.lastDone()!, true), { why: "changed" });
    // A delete is final; after 3 minutes nothing is left to undo.
    assert.equal((await run(deletePlan({ path: join(box.desktop, "notes.md"), isDirectory: false }, box.desktop, { ...DE, name: "notes.md" }), "d1")).outcome, "done");
    assert.deepEqual(await undoPlanOf(store.lastDone()!, true), { why: "delete" });
    now += FILE_OPS.undoTtlMs + 1;
    assert.equal(store.lastDone(), undefined);
  } finally {
    box.cleanup();
  }
});

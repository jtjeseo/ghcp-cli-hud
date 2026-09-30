import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";
import {
    createGitSyncUpdater, gitBranchKey, gitDirectoryKey, GIT_CHECK_MS, GIT_FETCH_MS,
    runGitCommand, runGitFetch, validGitSnapshot,
} from "../.github/extensions/hud-signal-bridge/git-sync.mjs";

const exec = promisify(execFile);
async function git(cwd, ...args) {
    const result = await exec("git", [
        "-C", cwd, "-c", `core.hooksPath=${process.platform === "win32" ? "NUL" : "/dev/null"}`, "-c", "commit.gpgsign=false",
        "-c", "user.name=HUD Fixture", "-c", "user.email=hud-fixture@example.invalid", ...args,
    ], { windowsHide: true });
    return result.stdout.trim();
}
async function fixture(t) {
    const base = await mkdtemp(join(tmpdir(), "hud-git-test-"));
    t.after(() => rm(base, { recursive: true, force: true }));
    const home = join(base, "home");
    const root = join(base, "root");
    const origin = join(base, "origin");
    await mkdir(home);
    await mkdir(root);
    await writeFile(join(home, "hud-git-sync.json"), '{"version":1,"enabled":true}');
    await git(base, "init", "--bare", "--quiet", "--initial-branch=main", origin);
    await git(root, "init", "--quiet", "--initial-branch=main");
    await git(root, "commit", "--quiet", "--allow-empty", "-m", "baseline");
    await git(root, "remote", "add", "origin", origin);
    await git(root, "push", "--quiet", "--set-upstream", "origin", "main");
    const key = gitDirectoryKey(join(root, ".git"));
    return {
        base, home, root, origin, key,
        async snapshot(directoryKey = key) {
            return JSON.parse(await readFile(join(home, "state", "hud-git-sync", `hud-git-${directoryKey}.json`), "utf8"));
        },
    };
}
async function update(updater, cwd) {
    updater.setWorkingDirectory(cwd);
    await updater.tick();
}
async function stalledTransport(f) {
    const pidPath = join(f.base, "transport.pid");
    const source = `[IO.File]::WriteAllText('${pidPath.replaceAll("'", "''")}', [string]$PID); Start-Sleep -Seconds 60`;
    const transport = join(f.base, "slow-transport.ps1");
    await writeFile(transport, source);
    // Store-packaged pwsh can be broker-activated outside the Git process tree.
    const transportHost = process.platform === "win32"
        ? join(process.env.SystemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
        : "pwsh";
    await git(f.root, "config", "remote.origin.uploadpack",
        `"${transportHost}" -NoProfile -NonInteractive -File "${transport}"`);
    return pidPath;
}
async function assertProcessStopped(pidPath) {
    const pid = Number(await readFile(pidPath, "utf8"));
    assert.ok(Number.isSafeInteger(pid) && pid > 0);
    if (process.platform === "win32") {
        // Windows kill(pid, 0) can report EPERM for an already-terminated process.
        const check = await exec("pwsh", ["-NoProfile", "-NonInteractive", "-Command",
            `$found = @([Diagnostics.Process]::GetProcesses() | Where-Object Id -eq ${pid}); ` +
            "try { [Console]::Out.Write([int]($found.Count -gt 0 -and -not $found[0].HasExited)) } " +
            "finally { foreach ($item in $found) { $item.Dispose() } }",
        ], { windowsHide: true, timeout: 5000 });
        assert.equal(check.stdout, "0", "stalled transport remains running");
    } else {
        assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
    }
}

test("real fetch reports ahead, behind and divergence without changing HEAD, index or worktree", async (t) => {
    const f = await fixture(t);
    let now = Date.now();
    let fetches = 0;
    const warnings = [];
    const updater = createGitSyncUpdater({
        home: f.home, clock: () => now, onWarning: (value) => warnings.push(value),
        fetch: async (params) => { fetches++; return runGitFetch(params); },
    });
    t.after(() => updater.stop());
    await update(updater, f.root);
    let snapshot = await f.snapshot();
    assert.equal(snapshot.status, "ok");
    assert.equal(snapshot.fetchStatus, "ok");
    assert.equal(snapshot.ahead, 0);
    assert.equal(snapshot.behind, 0);
    assert.equal(fetches, 1);
    assert.ok(validGitSnapshot(snapshot));
    await git(f.root, "commit", "--quiet", "--allow-empty", "-m", "outgoing");
    now += GIT_CHECK_MS;
    await updater.tick();
    assert.equal((await f.snapshot()).ahead, 1);
    assert.equal(fetches, 1);

    const peer = join(f.base, "peer");
    await git(f.base, "clone", "--quiet", f.origin, peer);
    await git(peer, "commit", "--quiet", "--allow-empty", "-m", "incoming-one");
    await git(peer, "commit", "--quiet", "--allow-empty", "-m", "incoming-two");
    await git(peer, "tag", "unfetched-tag");
    await git(peer, "push", "--quiet", "origin", "main", "--tags");
    await writeFile(join(f.root, "keep.txt"), "do not touch");
    const head = await git(f.root, "rev-parse", "HEAD");
    const index = await readFile(join(f.root, ".git", "index")).catch((error) => {
        if (error.code === "ENOENT") { return null; }
        throw error;
    });
    now += GIT_FETCH_MS;
    await updater.tick();
    snapshot = await f.snapshot();
    assert.deepEqual([snapshot.behind, snapshot.ahead], [2, 1]);
    assert.equal(await git(f.root, "rev-parse", "HEAD"), head);
    assert.equal(await readFile(join(f.root, "keep.txt"), "utf8"), "do not touch");
    assert.equal(await git(f.root, "tag", "--list"), "");
    if (index !== null) { assert.deepEqual(await readFile(join(f.root, ".git", "index")), index); }
    const serialized = JSON.stringify(snapshot);
    assert.ok(!serialized.includes(f.root) && !serialized.includes(f.origin));
    assert.ok(!serialized.includes("origin") && !serialized.includes("main"));
    assert.deepEqual(warnings, []);
});

test("same-worktree updaters coordinate one fetch and publish atomic bounded state", async (t) => {
    const f = await fixture(t);
    let fetches = 0;
    const fetch = async () => {
        fetches++;
        await new Promise((done) => setTimeout(done, 100));
        return "ok";
    };
    const a = createGitSyncUpdater({ home: f.home, fetch });
    const b = createGitSyncUpdater({ home: f.home, fetch });
    t.after(() => { a.stop(); b.stop(); });
    a.setWorkingDirectory(f.root);
    b.setWorkingDirectory(f.root);
    await Promise.all([a.tick(), b.tick()]);
    assert.equal(fetches, 1);
    assert.ok(validGitSnapshot(await f.snapshot()));
    const files = await readdir(join(f.home, "state", "hud-git-sync"));
    assert.equal(files.filter((name) => name.endsWith(".lock") || name.endsWith(".tmp")).length, 0);
});

test("linked worktrees have distinct caches but reuse the same upstream fetch schedule", async (t) => {
    const f = await fixture(t);
    let now = Date.now();
    let fetches = 0;
    const updater = createGitSyncUpdater({
        home: f.home, clock: () => now,
        fetch: async (params) => { fetches++; return runGitFetch(params); },
    });
    t.after(() => updater.stop());
    await update(updater, f.root);
    const linked = join(f.base, "linked");
    await git(f.root, "worktree", "add", "--quiet", "-b", "alternate", linked);
    await git(linked, "branch", "--set-upstream-to=origin/main");
    await git(linked, "commit", "--quiet", "--allow-empty", "-m", "linked outgoing");
    now += GIT_CHECK_MS;
    await update(updater, linked);
    const info = await runGitCommand(linked, ["rev-parse", "--absolute-git-dir"]);
    const linkedKey = gitDirectoryKey(info.output);
    assert.notEqual(linkedKey, f.key);
    const alternate = await f.snapshot(linkedKey);
    assert.equal(alternate.branchKey, gitBranchKey("alternate"));
    assert.equal(alternate.ahead, 1);
    assert.equal((await f.snapshot()).ahead, 0);
    assert.equal(fetches, 1);
});

test("failed fetch retains the last successful freshness and backs off before recovery", async (t) => {
    const f = await fixture(t);
    let now = Date.now();
    let calls = 0;
    let succeed = true;
    const warnings = [];
    const updater = createGitSyncUpdater({
        home: f.home, clock: () => now, onWarning: (value) => warnings.push(value),
        fetch: async () => { calls++; return succeed ? "ok" : "failed"; },
    });
    t.after(() => updater.stop());
    await update(updater, f.root);
    const initial = await f.snapshot();
    succeed = false;
    now += GIT_FETCH_MS;
    await updater.tick();
    const failed = await f.snapshot();
    assert.equal(failed.fetchStatus, "unavailable");
    assert.equal(failed.fetchedAt, initial.fetchedAt);
    assert.deepEqual([failed.ahead, failed.behind], [0, 0]);
    assert.deepEqual(warnings, ["fetch-unavailable"]);
    now += GIT_FETCH_MS;
    await updater.tick();
    assert.equal(calls, 2);
    succeed = true;
    now += GIT_FETCH_MS;
    await updater.tick();
    assert.equal(calls, 3);
    assert.equal((await f.snapshot()).fetchStatus, "ok");
});

test("no upstream, detached and unborn states never trigger a fetch", async (t) => {
    const f = await fixture(t);
    let now = Date.now();
    const updater = createGitSyncUpdater({
        home: f.home, clock: () => now, fetch: async () => { throw new Error("unexpected-fetch"); },
    });
    t.after(() => updater.stop());
    await git(f.root, "branch", "--unset-upstream");
    await update(updater, f.root);
    assert.equal((await f.snapshot()).status, "no-upstream");
    await git(f.root, "checkout", "--quiet", "--detach");
    now += GIT_CHECK_MS;
    await updater.tick();
    assert.equal((await f.snapshot()).status, "detached");
    const empty = join(f.base, "empty");
    await mkdir(empty);
    await git(empty, "init", "--quiet", "--initial-branch=main");
    now += GIT_CHECK_MS;
    await update(updater, empty);
    assert.equal((await f.snapshot(gitDirectoryKey(join(empty, ".git")))).status, "unborn");
});

test("local upstream counts do not request a remote fetch", async (t) => {
    const f = await fixture(t);
    await git(f.root, "branch", "local-base");
    await git(f.root, "branch", "--set-upstream-to=local-base");
    await git(f.root, "commit", "--quiet", "--allow-empty", "-m", "local ahead");
    const updater = createGitSyncUpdater({
        home: f.home, fetch: async () => { assert.fail("local upstream fetched"); },
    });
    t.after(() => updater.stop());
    await update(updater, f.root);
    const snapshot = await f.snapshot();
    assert.equal(snapshot.fetchStatus, "local");
    assert.equal(snapshot.ahead, 1);
});

test("a branch named detached remains an ordinary tracked branch", async (t) => {
    const f = await fixture(t);
    await git(f.root, "branch", "-m", "detached");
    await git(f.root, "commit", "--quiet", "--allow-empty", "-m", "outgoing");
    let fetches = 0;
    const updater = createGitSyncUpdater({
        home: f.home, fetch: async () => { fetches++; return "ok"; },
    });
    t.after(() => updater.stop());
    await update(updater, f.root);
    const snapshot = await f.snapshot();
    assert.equal(snapshot.status, "ok");
    assert.equal(snapshot.branchKey, gitBranchKey("detached"));
    assert.deepEqual([snapshot.ahead, snapshot.behind], [1, 0]);
    assert.equal(fetches, 1);
});

test("disabled or absent opt-in launches no git command; invalid config reports a fixed warning", async (t) => {
    const base = await mkdtemp(join(tmpdir(), "hud-git-options-"));
    t.after(() => rm(base, { recursive: true, force: true }));
    const warnings = [];
    const updater = createGitSyncUpdater({
        home: base, git: async () => { assert.fail("git ran without opt-in"); },
        onWarning: (value) => warnings.push(value),
    });
    t.after(() => updater.stop());
    await update(updater, base);
    await writeFile(join(base, "hud-git-sync.json"), '{"version":1,"enabled":false}');
    await updater.tick();
    assert.deepEqual(warnings, []);
    await writeFile(join(base, "hud-git-sync.json"), '{bad');
    await updater.tick();
    assert.deepEqual(warnings, ["sync-unavailable"]);
});

test("directory and branch keys are deterministic and snapshots reject unsafe values", () => {
    const key = gitDirectoryKey(process.cwd());
    assert.match(key, /^[a-f0-9]{64}$/);
    if (process.platform === "win32") { assert.equal(gitDirectoryKey(process.cwd().toUpperCase()), key); }
    assert.equal(gitBranchKey("main"), createHash("sha256").update("main").digest("hex"));
    const value = {
        version: 1, repositoryKey: key, branchKey: gitBranchKey("main"),
        updatedAt: 1000, status: "ok", ahead: 1, behind: 2, fetchedAt: 900, fetchStatus: "ok",
    };
    assert.ok(validGitSnapshot(value));
    assert.equal(validGitSnapshot({ ...value, ahead: -1 }), false);
    assert.equal(validGitSnapshot({ ...value, behind: "2" }), false);
    assert.equal(validGitSnapshot({ ...value, status: "made-up" }), false);
    assert.equal(validGitSnapshot({ ...value, extra: "private" }), false);
    assert.equal(validGitSnapshot(undefined), false);
});

test("fetch deadline kills a stalled transport and its descendant process", async (t) => {
    const f = await fixture(t);
    const pidPath = await stalledTransport(f);
    const started = Date.now();
    const reason = await runGitFetch({
        root: f.root, remote: "origin",
        refspec: "+refs/heads/main:refs/remotes/origin/main",
        home: f.home, deadlineMs: started + 6000,
    });
    assert.equal(reason, "timeout");
    assert.ok(Date.now() - started < 12000, "fetch exceeded its bounded deadline");
    await assertProcessStopped(pidPath);
});

test("disabling Git sync stops an in-flight fetch and its native transport", async (t) => {
    const f = await fixture(t);
    const pidPath = await stalledTransport(f);
    const started = Date.now();
    const pending = runGitFetch({
        root: f.root, remote: "origin",
        refspec: "+refs/heads/main:refs/remotes/origin/main", home: f.home,
    });
    let running = false;
    while (Date.now() - started < 8000) {
        try { await readFile(pidPath); running = true; break; } catch (error) {
            if (error.code !== "ENOENT") { throw error; }
        }
        await new Promise((done) => setTimeout(done, 50));
    }
    assert.ok(running, "transport did not start");
    await writeFile(join(f.home, "hud-git-sync.json"), '{"version":1,"enabled":false}');
    assert.equal(await pending, "stopped");
    assert.ok(Date.now() - started < 12000, "disabled fetch continued to its deadline");
    await assertProcessStopped(pidPath);
});

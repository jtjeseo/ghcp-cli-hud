import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { lstat, mkdir, open, readdir, rename, rmdir, unlink } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readHudOptIn } from "./configuration.mjs";

export const GIT_CHECK_MS = 15000;
export const GIT_FETCH_MS = 300000;
const LOCK_TTL_MS = 120000;
const MAX_BYTES = 4096;
const fetchScript = fileURLToPath(new URL("./git-fetch.ps1", import.meta.url));
const digest = (value) => createHash("sha256").update(value, "utf8").digest("hex");
const safeTime = (value) => Number.isSafeInteger(value) && value >= 0;

export function gitDirectoryKey(directory) {
    const normalized = resolve(directory).replace(/[A-Z]/g, (letter) =>
        process.platform === "win32" ? letter.toLowerCase() : letter
    );
    return digest(normalized);
}

export function gitBranchKey(branch) {
    return digest(branch);
}

async function readBytes(path, limit) {
    const handle = await open(path, "r");
    try {
        const size = (await handle.stat()).size;
        if (size <= 0 || size > limit) { throw new Error("invalid-size"); }
        const bytes = Buffer.alloc(size);
        let offset = 0;
        while (offset < size) {
            const { bytesRead } = await handle.read(bytes, offset, size - offset, offset);
            if (bytesRead === 0) { throw new Error("incomplete-read"); }
            offset += bytesRead;
        }
        return bytes;
    } finally {
        await handle.close();
    }
}

async function readJson(path, limit = MAX_BYTES) {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(await readBytes(path, limit)));
}

async function writeJson(path, value) {
    const bytes = Buffer.from(JSON.stringify(value));
    if (bytes.length > MAX_BYTES) { throw new Error("invalid-size"); }
    const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
    try {
        const handle = await open(temporary, "wx", 0o600);
        try { await handle.writeFile(bytes); } finally { await handle.close(); }
        await rename(temporary, path);
    } finally {
        try { await unlink(temporary); } catch (error) {
            if (error.code !== "ENOENT") { throw error; }
        }
    }
}

export async function gitSyncEnabled(home) {
    return readHudOptIn(home, "hud-git-sync.json");
}

function gitEnvironment() {
    const env = { ...process.env, GIT_TERMINAL_PROMPT: "0", GCM_INTERACTIVE: "never" };
    for (const key of Object.keys(env)) {
        if (/^GIT_(?:DIR|WORK_TREE|COMMON_DIR|INDEX_FILE|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|NAMESPACE|CONFIG(?:_COUNT|_KEY_\d+|_VALUE_\d+|_PARAMETERS)?)$/.test(key)) {
            delete env[key];
        }
    }
    return env;
}

export function runGitCommand(cwd, args) {
    return runProcess("git", [
        "-C", cwd, "-c", "core.fsmonitor=false", "-c",
        `core.hooksPath=${process.platform === "win32" ? "NUL" : "/dev/null"}`,
        "-c", "gc.auto=0", ...args,
    ], 5000);
}

function runProcess(program, args, timeout) {
    return new Promise((resolveResult, reject) => {
        const child = spawn(program, args, {
            env: gitEnvironment(), windowsHide: true, shell: false,
            stdio: ["ignore", "pipe", "ignore"],
        });
        let output = "";
        let size = 0;
        let failure = null;
        const timer = setTimeout(() => {
            failure = new Error("command-timeout");
            child.kill();
        }, timeout);
        child.stdout.setEncoding("utf8");
        child.stdout.on("data", (text) => {
            size += Buffer.byteLength(text, "utf8");
            if (size > 16384) {
                failure = new Error("output-limit");
                child.kill();
            } else { output += text; }
        });
        child.once("error", (error) => { clearTimeout(timer); reject(error); });
        child.once("close", (code) => {
            clearTimeout(timer);
            if (failure !== null) { reject(failure); }
            else { resolveResult({ code, output: output.trim() }); }
        });
    });
}

export async function runGitFetch({ root, remote, refspec, home, deadlineMs = Date.now() + 15000 }) {
    const result = process.platform === "darwin" ? await runProcess("/bin/bash", [
        fileURLToPath(new URL("./git-fetch.sh", import.meta.url)),
        root, remote, refspec, join(home, "hud-git-sync.json"),
        String(process.pid), String(deadlineMs),
    ], 20000) : await runProcess("pwsh", [
        "-NoLogo", "-NoProfile", "-NonInteractive", "-File", fetchScript,
        "-Repository", root, "-Remote", remote, "-Refspec", refspec,
        "-OptionsPath", join(home, "hud-git-sync.json"),
        "-OwnerProcessId", String(process.pid),
        "-DeadlineMs", String(deadlineMs),
    ], 20000);
    if (result.code !== 0) { return "unavailable"; }
    const value = JSON.parse(result.output);
    if (!["ok", "failed", "timeout", "stopped", "unavailable"].includes(value.reason)) {
        throw new Error("invalid-fetch-result");
    }
    return value.reason;
}

async function stateDirectory(home) {
    for (const path of [home, join(home, "state"), join(home, "state", "hud-git-sync")]) {
        await mkdir(path, { recursive: true, mode: 0o700 });
        const stat = await lstat(path);
        if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new Error("invalid-directory"); }
    }
    return join(home, "state", "hud-git-sync");
}

async function acquireLease(path, now) {
    try { await mkdir(path, { mode: 0o700 }); } catch (error) {
        if (error.code !== "EEXIST") { throw error; }
        const stat = await lstat(path);
        if (!stat.isDirectory() || stat.isSymbolicLink() ||
            now - stat.mtimeMs <= LOCK_TTL_MS) { return null; }
        const stale = `${path}.stale.${randomUUID()}`;
        try {
            if ((await readdir(path)).some((name) => name !== "owner.json")) { return null; }
            await rename(path, stale);
            try { await unlink(join(stale, "owner.json")); } catch (cleanupError) {
                if (cleanupError.code !== "ENOENT") { throw cleanupError; }
            }
            await rmdir(stale);
            await mkdir(path, { mode: 0o700 });
        } catch (race) {
            if (["ENOENT", "EEXIST"].includes(race.code)) { return null; }
            throw race;
        }
    }
    const owner = randomUUID();
    const ownerPath = join(path, "owner.json");
    try { await writeJson(ownerPath, { owner }); } catch (error) {
        await rmdir(path);
        throw error;
    }
    return {
        async release() {
            try {
                if ((await readJson(ownerPath)).owner !== owner) { return; }
                await unlink(ownerPath);
                await rmdir(path);
            } catch (error) {
                if (error.code !== "ENOENT") { throw error; }
            }
        },
    };
}

async function getContext(cwd, git) {
    if (typeof cwd !== "string" || !isAbsolute(cwd) || cwd.includes("\0") ||
        (process.platform === "win32" && !/^[A-Za-z]:[\\/]/.test(cwd))) { return null; }
    const stat = await lstat(cwd);
    if (!stat.isDirectory() || stat.isSymbolicLink()) { return null; }
    const result = await git(cwd, [
        "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir",
    ]);
    if (result.code !== 0) { return null; }
    const lines = result.output.split(/\r?\n/);
    if (lines.length !== 3 || lines.some((line) => !isAbsolute(line))) {
        throw new Error("invalid-context");
    }
    const [root, directory, common] = lines.map((line) => resolve(line));
    for (const path of [root, directory, common]) {
        const info = await lstat(path);
        if (!info.isDirectory() || info.isSymbolicLink()) { throw new Error("invalid-context"); }
    }
    const headPath = join(directory, "HEAD");
    const headStat = await lstat(headPath);
    if (!headStat.isFile() || headStat.isSymbolicLink() || headStat.size > 1024) {
        throw new Error("invalid-head");
    }
    const head = new TextDecoder("utf-8", { fatal: true }).decode(await readBytes(headPath, 1024)).trim();
    const match = /^ref: refs\/heads\/([^\r\n]+)$/.exec(head);
    const branch = match ? match[1] : "detached";
    if (!match && !/^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$/.test(head)) {
        throw new Error("invalid-head");
    }
    return { root, directory, common, branch, detached: !match, repositoryKey: gitDirectoryKey(directory) };
}

function validSchedule(value) {
    return value !== null && Object.keys(value).length === 6 && value.version === 1 &&
        safeTime(value.nextAt) && safeTime(value.attemptAt) &&
        (value.successAt === null || safeTime(value.successAt)) &&
        Number.isInteger(value.failures) && value.failures >= 0 && value.failures <= 6 &&
        ["ok", "unavailable", "pending"].includes(value.status);
}

export function validGitSnapshot(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value) &&
        Object.keys(value).length === 9 &&
        value.version === 1 && /^[a-f0-9]{64}$/.test(value.repositoryKey) &&
        /^[a-f0-9]{64}$/.test(value.branchKey) && safeTime(value.updatedAt) &&
        ["ok", "no-upstream", "unborn", "detached", "unavailable"].includes(value.status) &&
        ["ok", "local", "pending", "unavailable", "not-needed"].includes(value.fetchStatus) &&
        (value.fetchedAt === null || (safeTime(value.fetchedAt) && value.fetchedAt <= value.updatedAt + 5000)) &&
        (value.status === "ok" ? safeTime(value.ahead) && safeTime(value.behind)
            : value.ahead === null && value.behind === null);
}

async function fetchUpstream(context, upstream, directory, options) {
    const { clock, fetch, home, warning, isActive } = options;
    if (upstream.remote === ".") { return { status: "local", successAt: null }; }
    if (!/^[A-Za-z0-9_][A-Za-z0-9_./-]{0,127}$/.test(upstream.remote) ||
        !/^refs\/heads\/[^:\s]+$/.test(upstream.source) ||
        !/^refs\/remotes\/[^:\s]+$/.test(upstream.target)) {
        warning("fetch-unavailable");
        return { status: "unavailable", successAt: null };
    }
    const key = digest(`${gitDirectoryKey(context.common)}\0${upstream.remote}\0${upstream.source}\0${upstream.target}`);
    const path = join(directory, `fetch-${key}.json`);
    let schedule = { version: 1, nextAt: 0, attemptAt: 0, successAt: null, failures: 0, status: "pending" };
    async function readSchedule() {
        try {
            const value = await readJson(path);
            if (!validSchedule(value)) { throw new Error("invalid-schedule"); }
            schedule = value;
        } catch (error) {
            if (error.code !== "ENOENT") { warning("state-unavailable"); }
        }
    }
    await readSchedule();
    if (clock() < schedule.nextAt) { return schedule; }
    if (!isActive() || !await gitSyncEnabled(home)) { return schedule; }
    const lease = await acquireLease(join(directory, `fetch-${gitDirectoryKey(context.common)}.lock`), clock());
    if (lease === null) { return schedule; }
    try {
        await readSchedule();
        if (clock() < schedule.nextAt) { return schedule; }
        if (!isActive() || !await gitSyncEnabled(home)) { return schedule; }
        const attemptAt = clock();
        schedule = { ...schedule, attemptAt, nextAt: attemptAt + GIT_FETCH_MS, status: "pending" };
        await writeJson(path, schedule);
        let result = "unavailable";
        try {
            result = await fetch({
                root: context.root, remote: upstream.remote,
                refspec: `+${upstream.source}:${upstream.target}`, home,
            });
        } catch { warning("fetch-unavailable"); }
        const ok = result === "ok";
        const failures = ok ? 0 : Math.min(6, schedule.failures + 1);
        schedule = {
            version: 1, attemptAt, successAt: ok ? clock() : schedule.successAt,
            failures, status: ok ? "ok" : "unavailable",
            nextAt: clock() + Math.min(1800000, GIT_FETCH_MS * (2 ** failures)),
        };
        if (!ok) { warning("fetch-unavailable"); }
        await writeJson(path, schedule);
        return schedule;
    } finally { await lease.release(); }
}

async function refresh(context, directory, options) {
    const { git, clock } = options;
    const snapshot = {
        version: 1, repositoryKey: context.repositoryKey, branchKey: gitBranchKey(context.branch),
        updatedAt: clock(), status: "detached", ahead: null, behind: null,
        fetchedAt: null, fetchStatus: "not-needed",
    };
    if (context.detached) { return snapshot; }
    const metadata = await git(context.root, [
        "for-each-ref", "--format=%(refname)%00%(upstream)%00%(upstream:remotename)%00%(upstream:remoteref)",
        `refs/heads/${context.branch}`,
    ]);
    if (metadata.code !== 0) { throw new Error("metadata-unavailable"); }
    if (metadata.output === "") { snapshot.status = "unborn"; return snapshot; }
    const row = metadata.output.split(/\r?\n/).find((line) =>
        line.split("\0")[0] === `refs/heads/${context.branch}`
    );
    if (!row) { throw new Error("metadata-unavailable"); }
    const [ref, target, remote, source] = row.split("\0");
    if (row.split("\0").length !== 4) { throw new Error("invalid-metadata"); }
    if (!target) { snapshot.status = "no-upstream"; return snapshot; }
    const schedule = await fetchUpstream(context, { target, remote, source }, directory, options);
    snapshot.fetchedAt = schedule.successAt;
    snapshot.fetchStatus = schedule.status;
    const counts = await git(context.root, ["rev-list", "--left-right", "--count", `${ref}...${target}`]);
    snapshot.updatedAt = clock();
    if (counts.code !== 0 || !/^\d+\s+\d+$/.test(counts.output)) {
        snapshot.status = "unavailable";
        return snapshot;
    }
    [snapshot.ahead, snapshot.behind] = counts.output.split(/\s+/).map(Number);
    if (![snapshot.ahead, snapshot.behind].every(safeTime)) { throw new Error("invalid-counts"); }
    snapshot.status = "ok";
    return snapshot;
}

async function pruneState(directory, now) {
    const entries = [];
    const abandoned = [];
    for (const entry of await readdir(directory, { withFileTypes: true })) {
        if (!entry.isFile()) { continue; }
        const record = /^(?:hud-git|fetch)-[a-f0-9]{64}\.json$/.test(entry.name);
        const temporary = /^(?:hud-git|fetch)-[a-f0-9]{64}\.json\.\d+\.[a-f0-9-]{36}\.tmp$/.test(entry.name);
        if (record || temporary) {
            const path = join(directory, entry.name);
            try {
                const at = (await lstat(path)).mtimeMs;
                if (record) { entries.push({ path, at }); }
                else if (now - at > LOCK_TTL_MS) { abandoned.push({ path }); }
            } catch (error) {
                if (error.code !== "ENOENT") { throw error; }
            }
        }
    }
    entries.sort((left, right) => right.at - left.at);
    const expired = entries.filter((entry, index) =>
        index >= 128 || now - entry.at > 604800000
    );
    for (const entry of [...expired, ...abandoned].slice(0, 32)) {
        try { await unlink(entry.path); } catch (error) {
            if (error.code !== "ENOENT") { throw error; }
        }
    }
}

export function createGitSyncUpdater({
    home, onWarning = () => {}, git = runGitCommand, fetch = runGitFetch, clock = Date.now,
}) {
    let cwd = null;
    let active = null;
    let timer = null;
    let stopped = false;
    const warned = new Set();
    function warning(category) {
        if (!warned.has(category)) {
            warned.add(category);
            try { onWarning(category); } catch {}
        }
    }
    async function update() {
        if (stopped || cwd === null || !await gitSyncEnabled(home)) { return; }
        const requestedDirectory = cwd;
        const context = await getContext(requestedDirectory, git);
        if (context === null) { return; }
        const directory = await stateDirectory(home);
        const path = join(directory, `hud-git-${context.repositoryKey}.json`);
        const lease = await acquireLease(join(directory, `snapshot-${context.repositoryKey}.lock`), clock());
        if (lease === null) { return; }
        try {
            try {
                const cached = await readJson(path);
                if (!validGitSnapshot(cached)) { throw new Error("invalid-snapshot"); }
                if (cached.repositoryKey === context.repositoryKey &&
                    cached.branchKey === gitBranchKey(context.branch) &&
                    (cached.status === "detached") === context.detached &&
                    safeTime(cached.updatedAt) && clock() >= cached.updatedAt &&
                    clock() - cached.updatedAt < GIT_CHECK_MS) { return; }
            } catch (error) {
                if (error.code !== "ENOENT") { warning("state-unavailable"); }
            }
            let snapshot;
            try {
                snapshot = await refresh(context, directory, {
                    home, git, fetch, clock, warning,
                    isActive: () => !stopped && cwd === requestedDirectory,
                });
            } catch {
                warning("sync-unavailable");
                snapshot = {
                    version: 1, repositoryKey: context.repositoryKey,
                    branchKey: gitBranchKey(context.branch), updatedAt: clock(),
                    status: "unavailable", ahead: null, behind: null,
                    fetchedAt: null, fetchStatus: "unavailable",
                };
            }
            await writeJson(path, snapshot);
            await pruneState(directory, clock());
        } finally { await lease.release(); }
    }
    function tick() {
        if (active !== null) { return active; }
        active = update().catch(() => warning("sync-unavailable")).finally(() => { active = null; });
        return active;
    }
    return {
        setWorkingDirectory(value) {
            cwd = typeof value === "string" && isAbsolute(value) ? value : null;
            void tick();
        },
        tick,
        start() {
            if (timer === null) { timer = setInterval(tick, GIT_CHECK_MS); timer.unref(); }
        },
        stop() { stopped = true; clearInterval(timer); timer = null; },
    };
}

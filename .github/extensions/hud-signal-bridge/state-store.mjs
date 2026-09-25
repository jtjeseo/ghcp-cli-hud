import { randomUUID } from "node:crypto";
import {
    lstat,
    mkdir,
    readdir,
    realpath,
    rename,
    stat,
    unlink,
    writeFile,
} from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

const MAX_STATE_BYTES = 4096;
const MAX_STATE_FILES = 64;
const STALE_STATE_MS = 24 * 60 * 60 * 1000;
const STALE_TEMP_MS = 15 * 60 * 1000;
const SESSION_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const TRANSIENT_RENAME_ERRORS = new Set(["EACCES", "EBUSY", "EPERM"]);
const PHASES = new Set(["working", "running_tool", "complete", "idle"]);
const STATE_KEYS = new Set([
    "version",
    "sessionId",
    "updatedAtMs",
    "phase",
    "phaseAtMs",
    "recentIncreaseNanoAiu",
    "recentAtMs",
]);

function isSafeInteger(value) {
    return Number.isSafeInteger(value) && value >= 0;
}

function isWithin(parent, child) {
    const childRelative = relative(parent, child);
    return childRelative !== "" &&
        childRelative !== ".." &&
        !childRelative.startsWith(`..${sep}`) &&
        !isAbsolute(childRelative);
}

function validateSnapshot(snapshot, sessionId) {
    if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot)) {
        throw new Error("Signal snapshot has an invalid shape");
    }
    const keys = Object.keys(snapshot);
    if (keys.length !== STATE_KEYS.size ||
        keys.some((key) => !STATE_KEYS.has(key))) {
        throw new Error("Signal snapshot contains unapproved fields");
    }
    if (snapshot.version !== 1 ||
        snapshot.sessionId !== sessionId ||
        !isSafeInteger(snapshot.updatedAtMs)) {
        throw new Error("Signal snapshot has invalid identity or timestamp fields");
    }
    if (snapshot.phase !== null &&
        (!PHASES.has(snapshot.phase) || !isSafeInteger(snapshot.phaseAtMs))) {
        throw new Error("Signal snapshot has an invalid phase");
    }
    if (snapshot.phase === null && snapshot.phaseAtMs !== null) {
        throw new Error("Signal snapshot has an orphaned phase timestamp");
    }
    if (snapshot.recentIncreaseNanoAiu !== null) {
        if (!isSafeInteger(snapshot.recentIncreaseNanoAiu) ||
            !isSafeInteger(snapshot.recentAtMs)) {
            throw new Error("Signal snapshot has an invalid checkpoint difference");
        }
    } else if (snapshot.recentAtMs !== null) {
        throw new Error("Signal snapshot has an orphaned checkpoint timestamp");
    }

    return {
        version: snapshot.version,
        sessionId: snapshot.sessionId,
        updatedAtMs: snapshot.updatedAtMs,
        phase: snapshot.phase,
        phaseAtMs: snapshot.phaseAtMs,
        recentIncreaseNanoAiu: snapshot.recentIncreaseNanoAiu,
        recentAtMs: snapshot.recentAtMs,
    };
}

async function removeIfExpired(path, cutoffMs) {
    let info;
    try {
        info = await stat(path);
    } catch (error) {
        if (error?.code === "ENOENT") {
            return null;
        }
        throw new Error("Could not inspect an old HUD signal file");
    }
    if (info.mtimeMs < cutoffMs) {
        try {
            await unlink(path);
        } catch (error) {
            if (error?.code !== "ENOENT") {
                throw new Error("Could not prune an expired HUD signal file");
            }
        }
        return null;
    }
    return info.mtimeMs;
}

async function pruneStateDirectory(directory, currentPath) {
    const now = Date.now();
    let entries;
    try {
        entries = await readdir(directory, { withFileTypes: true });
    } catch {
        throw new Error("Could not inspect the HUD signal state directory");
    }

    const stateFiles = [];
    for (const entry of entries) {
        if (!entry.isFile()) {
            continue;
        }
        const path = join(directory, entry.name);
        const temporary = /^hud-signal-[A-Za-z0-9_-]{1,128}\.json\.\d+\.[0-9a-f-]{36}\.tmp$/.test(entry.name);
        const stateFile = /^hud-signal-[A-Za-z0-9_-]{1,128}\.json$/.test(entry.name);
        if (!temporary && !stateFile) {
            continue;
        }

        if (temporary) {
            await removeIfExpired(path, now - STALE_TEMP_MS);
            continue;
        }

        const modifiedAtMs = await removeIfExpired(
            path,
            path === currentPath ? Number.NEGATIVE_INFINITY : now - STALE_STATE_MS
        );
        if (modifiedAtMs !== null) {
            stateFiles.push({ path, modifiedAtMs });
        }
    }

    const currentFileExists = stateFiles.some((file) => file.path === currentPath);
    const maximumExistingFiles = currentFileExists
        ? MAX_STATE_FILES
        : MAX_STATE_FILES - 1;
    if (stateFiles.length > maximumExistingFiles) {
        stateFiles.sort((left, right) => left.modifiedAtMs - right.modifiedAtMs);
        const excess = stateFiles.length - maximumExistingFiles;
        let removed = 0;
        for (const file of stateFiles) {
            if (removed >= excess) {
                break;
            }
            if (file.path === currentPath) {
                continue;
            }
            try {
                await unlink(file.path);
            } catch (error) {
                if (error?.code !== "ENOENT") {
                    throw new Error("Could not prune an excess HUD signal file");
                }
            }
            removed += 1;
        }
    }
}

async function writeSnapshotAtomically(path, snapshot) {
    const serialized = JSON.stringify(snapshot);
    if (Buffer.byteLength(serialized, "utf8") > MAX_STATE_BYTES) {
        throw new Error("HUD signal snapshot exceeded its configured size bound");
    }

    const temporaryPath = `${path}.${process.pid}.${randomUUID()}.tmp`;
    let temporaryMayExist = true;
    try {
        await writeFile(temporaryPath, serialized, {
            encoding: "utf8",
            flag: "wx",
            mode: 0o600,
        });
        let renamed = false;
        for (let attempt = 0; attempt < 8; attempt += 1) {
            try {
                await rename(temporaryPath, path);
                renamed = true;
                break;
            } catch (error) {
                const retryable = process.platform === "win32" &&
                    TRANSIENT_RENAME_ERRORS.has(error?.code);
                if (!retryable || attempt === 7) {
                    throw new Error("Could not atomically replace the HUD signal snapshot");
                }
                await new Promise((resolve) => setTimeout(resolve, 5 * (attempt + 1)));
            }
        }
        if (!renamed) {
            throw new Error("Could not atomically replace the HUD signal snapshot");
        }
        temporaryMayExist = false;
    } finally {
        if (temporaryMayExist) {
            try {
                await unlink(temporaryPath);
            } catch (error) {
                if (error?.code !== "ENOENT") {
                    throw new Error("Could not remove an incomplete HUD signal snapshot");
                }
            }
        }
    }
}

export async function createSignalStateStore(copilotHome, sessionId) {
    if (typeof copilotHome !== "string" || !isAbsolute(copilotHome) ||
        typeof sessionId !== "string" || !SESSION_ID_PATTERN.test(sessionId)) {
        throw new TypeError("An absolute COPILOT_HOME and safe session ID are required");
    }
    if (process.platform === "win32" &&
        !/^[A-Za-z]:[\\/]/.test(copilotHome)) {
        throw new TypeError("COPILOT_HOME must be on a local Windows drive");
    }

    const homePath = resolve(copilotHome);
    await mkdir(homePath, { recursive: true, mode: 0o700 });
    const realHome = await realpath(homePath);
    const stateDirectory = resolve(homePath, "state", "hud-signal-bridge");
    if (!isWithin(homePath, stateDirectory)) {
        throw new Error("HUD signal state must be inside COPILOT_HOME");
    }

    await mkdir(stateDirectory, { recursive: true, mode: 0o700 });
    const directoryInfo = await lstat(stateDirectory);
    const realStateDirectory = await realpath(stateDirectory);
    if (!directoryInfo.isDirectory() ||
        directoryInfo.isSymbolicLink() ||
        !isWithin(realHome, realStateDirectory)) {
        throw new Error("HUD signal state directory is not private local storage");
    }

    const path = join(stateDirectory, `hud-signal-${sessionId}.json`);
    await pruneStateDirectory(stateDirectory, path);

    let writeTail = Promise.resolve();
    return {
        write(snapshot) {
            const safeSnapshot = validateSnapshot(snapshot, sessionId);
            const write = writeTail.then(() =>
                writeSnapshotAtomically(path, safeSnapshot)
            );
            writeTail = write.catch(() => undefined);
            return write;
        },
    };
}

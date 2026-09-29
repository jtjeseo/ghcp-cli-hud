import { randomUUID } from "node:crypto";
import {
    lstat,
    mkdir,
    readFile,
    readdir,
    realpath,
    rename,
    stat,
    unlink,
    writeFile,
} from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import {
    AIC_VALIDATION_REASONS,
    MAX_ACTIVE_SUBAGENTS,
    SUBAGENT_COUNT_CHANGE_REASONS,
    TOOL_CORRELATION_DIAGNOSTIC_REASONS,
} from "./state-machine.mjs";

const MAX_STATE_BYTES = 4096;
const MAX_STATE_FILES = 64;
const STALE_STATE_MS = 24 * 60 * 60 * 1000;
const STALE_TEMP_MS = 15 * 60 * 1000;
const MAX_DIAGNOSTIC_RECORDS = 32;
const MAX_DIAGNOSTIC_FILES = 64;
const DIAGNOSTIC_RETENTION_MS = 24 * 60 * 60 * 1000;
const DIAGNOSTIC_STALE_TEMP_MS = 15 * 60 * 1000;
const AIC_VALIDATION_KEYS = new Set([
    "version",
    "validity",
    "reason",
    "baselineNanoAiu",
    "finalCheckpointNanoAiu",
    "computedDifferenceNanoAiu",
    "displayedIncreaseNanoAiu",
    "eventOrder",
]);
const AIC_VALIDATION_ORDER_KEYS = new Set([
    "bridgeSessionMatched",
    "baselineBeforeInterval",
    "rootTurnsStarted",
    "rootTurnsEnded",
    "rootTurnCountCapped",
    "rootTurnsClosed",
    "finalCheckpointAccepted",
    "finalCheckpointAfterTurnEnd",
    "idleAfterFinalCheckpoint",
    "toolCallsClosed",
    "overlapObserved",
    "interruptionObserved",
    "resetObserved",
    "counterResetObserved",
    "unverifiedSubagentActivity",
]);
const SESSION_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const TRANSIENT_RENAME_ERRORS = new Set(["EACCES", "EBUSY", "EPERM"]);
const MAX_RENAME_ATTEMPTS = 12;
const RENAME_RETRY_BASE_MS = 5;
const RENAME_RETRY_MAX_MS = 50;
const DIAGNOSTIC_REASONS = new Set([
    ...SUBAGENT_COUNT_CHANGE_REASONS,
    ...TOOL_CORRELATION_DIAGNOSTIC_REASONS,
]);
const TOOL_DIAGNOSTIC_REASONS = new Set(TOOL_CORRELATION_DIAGNOSTIC_REASONS);
const TOOL_DIAGNOSTIC_FIELDS = [
    "rootInterval",
    "caller",
    "parentCorrelation",
];
const AIC_VALIDATION_REASON_SET = new Set(AIC_VALIDATION_REASONS);
const PHASES = new Set(["working", "running_tool", "complete", "idle"]);
const STATE_KEYS = new Set([
    "version",
    "sessionId",
    "updatedAtMs",
    "phase",
    "phaseAtMs",
    "recentIncreaseNanoAiu",
    "recentAtMs",
    "activeSubagentCount",
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

function samePath(left, right) {
    return process.platform === "win32"
        ? left.toLowerCase() === right.toLowerCase()
        : left === right;
}

export async function isDisposableCopilotHome(copilotHome) {
    if (typeof copilotHome !== "string" || !isAbsolute(copilotHome)) {
        return false;
    }

    let realTemp;
    let realHome;
    try {
        realTemp = await realpath(tmpdir());
        realHome = await realpath(copilotHome);
    } catch (error) {
        if (error?.code === "ENOENT") {
            return false;
        }
        throw new Error("Could not verify the disposable diagnostic home");
    }

    const profile = process.env.USERPROFILE || homedir();
    const normalHomePath = resolve(profile, ".copilot");
    let normalHome = normalHomePath;
    try {
        normalHome = await realpath(normalHomePath);
    } catch (error) {
        if (error?.code !== "ENOENT") {
            return false;
        }
    }

    const insideNormalHome = samePath(realHome, normalHome) ||
        isWithin(normalHome, realHome);
    return !insideNormalHome && isWithin(realTemp, realHome);
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
    if (snapshot.activeSubagentCount !== null &&
        (!isSafeInteger(snapshot.activeSubagentCount) ||
            snapshot.activeSubagentCount > MAX_ACTIVE_SUBAGENTS)) {
        throw new Error("Signal snapshot has an invalid active subagent count");
    }

    return {
        version: snapshot.version,
        sessionId: snapshot.sessionId,
        updatedAtMs: snapshot.updatedAtMs,
        phase: snapshot.phase,
        phaseAtMs: snapshot.phaseAtMs,
        recentIncreaseNanoAiu: snapshot.recentIncreaseNanoAiu,
        recentAtMs: snapshot.recentAtMs,
        activeSubagentCount: snapshot.activeSubagentCount,
    };
}

function validateTransition(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw new Error("A transition diagnostic has an invalid shape");
    }
    const keys = Object.keys(value);
    const toolDiagnostic = typeof value.reason === "string" &&
        TOOL_DIAGNOSTIC_REASONS.has(value.reason);
    const expectedKeys = toolDiagnostic
        ? ["atMs", "reason", "previousCount", "nextCount", ...TOOL_DIAGNOSTIC_FIELDS]
        : ["atMs", "reason", "previousCount", "nextCount"];
    if (keys.length !== expectedKeys.length ||
        keys.some((key) => !expectedKeys.includes(key))) {
        throw new Error("A transition diagnostic contains unapproved fields");
    }
    if (!Number.isSafeInteger(value.atMs) || value.atMs < 0 ||
        typeof value.reason !== "string" ||
        !DIAGNOSTIC_REASONS.has(value.reason)) {
        throw new Error("A transition diagnostic has invalid time or reason fields");
    }
    const validCount = (count) => count === null ||
        (Number.isSafeInteger(count) &&
            count >= 0 &&
            count <= MAX_ACTIVE_SUBAGENTS);
    if (!validCount(value.previousCount) ||
        !validCount(value.nextCount) ||
        (toolDiagnostic
            ? value.previousCount !== value.nextCount
            : value.previousCount === value.nextCount)) {
        throw new Error("A transition diagnostic has invalid count fields");
    }
    if (toolDiagnostic &&
        (!["absent", "open", "closed"].includes(value.rootInterval) ||
            !["root", "subagent", "unknown"].includes(value.caller) ||
            !["matched", "missing", "unmatched"].includes(value.parentCorrelation))) {
        throw new Error("A tool diagnostic has invalid categorical context");
    }

    const safeTransition = {
        atMs: value.atMs,
        reason: value.reason,
        previousCount: value.previousCount,
        nextCount: value.nextCount,
    };
    if (toolDiagnostic) {
        safeTransition.rootInterval = value.rootInterval;
        safeTransition.caller = value.caller;
        safeTransition.parentCorrelation = value.parentCorrelation;
    }
    return safeTransition;
}

function validateAicValidation(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw new Error("An AIC validation record has an invalid shape");
    }
    const keys = Object.keys(value);
    if (keys.length !== AIC_VALIDATION_KEYS.size ||
        keys.some((key) => !AIC_VALIDATION_KEYS.has(key))) {
        throw new Error("An AIC validation record contains unapproved fields");
    }
    if (value.version !== 1 ||
        !["pending", "valid", "suppressed"].includes(value.validity) ||
        !AIC_VALIDATION_REASON_SET.has(value.reason)) {
        throw new Error("An AIC validation record has invalid category fields");
    }

    const validTotal = (total) => total === null || isSafeInteger(total);
    if (!validTotal(value.baselineNanoAiu) ||
        !validTotal(value.finalCheckpointNanoAiu) ||
        (value.computedDifferenceNanoAiu !== null &&
            !Number.isSafeInteger(value.computedDifferenceNanoAiu)) ||
        !validTotal(value.displayedIncreaseNanoAiu)) {
        throw new Error("An AIC validation record has invalid numeric fields");
    }

    const eventOrder = value.eventOrder;
    if (!eventOrder || typeof eventOrder !== "object" ||
        Array.isArray(eventOrder)) {
        throw new Error("An AIC validation record has invalid event-order fields");
    }
    const orderKeys = Object.keys(eventOrder);
    if (orderKeys.length !== AIC_VALIDATION_ORDER_KEYS.size ||
        orderKeys.some((key) => !AIC_VALIDATION_ORDER_KEYS.has(key))) {
        throw new Error("An AIC validation record has unapproved event-order fields");
    }
    for (const key of AIC_VALIDATION_ORDER_KEYS) {
        if (typeof eventOrder[key] !== "boolean" &&
            !["rootTurnsStarted", "rootTurnsEnded"].includes(key)) {
            throw new Error("An AIC event-order indicator is invalid");
        }
    }
    if (!Number.isSafeInteger(eventOrder.rootTurnsStarted) ||
        eventOrder.rootTurnsStarted < 0 ||
        eventOrder.rootTurnsStarted > 32 ||
        !Number.isSafeInteger(eventOrder.rootTurnsEnded) ||
        eventOrder.rootTurnsEnded < 0 ||
        eventOrder.rootTurnsEnded > 32) {
        throw new Error("An AIC root-turn count is outside its bound");
    }

    const expectedDifference = value.baselineNanoAiu !== null &&
        value.finalCheckpointNanoAiu !== null
        ? value.finalCheckpointNanoAiu - value.baselineNanoAiu
        : null;
    if (value.computedDifferenceNanoAiu !== expectedDifference) {
        throw new Error("An AIC checkpoint difference does not match its totals");
    }
    if (value.validity === "pending") {
        if (value.reason !== "baseline-accepted" ||
            value.baselineNanoAiu === null ||
            value.finalCheckpointNanoAiu !== null ||
            value.computedDifferenceNanoAiu !== null ||
            value.displayedIncreaseNanoAiu !== null ||
            !eventOrder.baselineBeforeInterval) {
            throw new Error("A pending AIC validation is not a baseline record");
        }
    } else if (value.validity === "valid") {
        const validOrder = eventOrder.bridgeSessionMatched &&
            eventOrder.baselineBeforeInterval &&
            eventOrder.rootTurnsStarted > 0 &&
            eventOrder.rootTurnsStarted === eventOrder.rootTurnsEnded &&
            eventOrder.rootTurnsClosed &&
            eventOrder.finalCheckpointAccepted &&
            eventOrder.finalCheckpointAfterTurnEnd &&
            eventOrder.idleAfterFinalCheckpoint &&
            eventOrder.toolCallsClosed &&
            !eventOrder.overlapObserved &&
            !eventOrder.interruptionObserved &&
            !eventOrder.resetObserved &&
            !eventOrder.counterResetObserved &&
            !eventOrder.unverifiedSubagentActivity;
        if (value.reason !== "valid" || !validOrder ||
            value.baselineNanoAiu === null ||
            value.finalCheckpointNanoAiu === null ||
            value.computedDifferenceNanoAiu < 0 ||
            value.displayedIncreaseNanoAiu !==
                value.computedDifferenceNanoAiu) {
            throw new Error("A valid AIC record has ambiguous boundaries or arithmetic");
        }
    } else if (value.reason === "valid" ||
        value.reason === "baseline-accepted" ||
        value.displayedIncreaseNanoAiu !== null) {
        throw new Error("A suppressed AIC record contains a displayable increase");
    }

    return {
        version: value.version,
        validity: value.validity,
        reason: value.reason,
        baselineNanoAiu: value.baselineNanoAiu,
        finalCheckpointNanoAiu: value.finalCheckpointNanoAiu,
        computedDifferenceNanoAiu: value.computedDifferenceNanoAiu,
        displayedIncreaseNanoAiu: value.displayedIncreaseNanoAiu,
        eventOrder: {
            bridgeSessionMatched: eventOrder.bridgeSessionMatched,
            baselineBeforeInterval: eventOrder.baselineBeforeInterval,
            rootTurnsStarted: eventOrder.rootTurnsStarted,
            rootTurnsEnded: eventOrder.rootTurnsEnded,
            rootTurnCountCapped: eventOrder.rootTurnCountCapped,
            rootTurnsClosed: eventOrder.rootTurnsClosed,
            finalCheckpointAccepted: eventOrder.finalCheckpointAccepted,
            finalCheckpointAfterTurnEnd:
                eventOrder.finalCheckpointAfterTurnEnd,
            idleAfterFinalCheckpoint:
                eventOrder.idleAfterFinalCheckpoint,
            toolCallsClosed: eventOrder.toolCallsClosed,
            overlapObserved: eventOrder.overlapObserved,
            interruptionObserved: eventOrder.interruptionObserved,
            resetObserved: eventOrder.resetObserved,
            counterResetObserved: eventOrder.counterResetObserved,
            unverifiedSubagentActivity:
                eventOrder.unverifiedSubagentActivity,
        },
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

async function pruneDiagnosticDirectory(directory, currentPath) {
    const now = Date.now();
    let entries;
    try {
        entries = await readdir(directory, { withFileTypes: true });
    } catch {
        throw new Error("Could not inspect the transition diagnostic directory");
    }

    const diagnosticFiles = [];
    for (const entry of entries) {
        if (!entry.isFile()) {
            continue;
        }
        const path = join(directory, entry.name);
        const temporary = /^hud-subagent-count-changes-[A-Za-z0-9_-]{1,128}\.json\.\d+\.[0-9a-f-]{36}\.tmp$/.test(entry.name);
        const diagnostic = /^hud-subagent-count-changes-[A-Za-z0-9_-]{1,128}\.json$/.test(entry.name);
        if (!temporary && !diagnostic) {
            continue;
        }

        if (temporary) {
            await removeIfExpired(path, now - DIAGNOSTIC_STALE_TEMP_MS);
            continue;
        }
        const modifiedAtMs = await removeIfExpired(
            path,
            path === currentPath
                ? Number.NEGATIVE_INFINITY
                : now - DIAGNOSTIC_RETENTION_MS
        );
        if (modifiedAtMs !== null) {
            diagnosticFiles.push({ path, modifiedAtMs });
        }
    }

    const currentFileExists = diagnosticFiles.some(
        (file) => file.path === currentPath
    );
    const maximumExistingFiles = currentFileExists
        ? MAX_DIAGNOSTIC_FILES
        : MAX_DIAGNOSTIC_FILES - 1;
    if (diagnosticFiles.length > maximumExistingFiles) {
        diagnosticFiles.sort((left, right) => left.modifiedAtMs - right.modifiedAtMs);
        const excess = diagnosticFiles.length - maximumExistingFiles;
        let removed = 0;
        for (const file of diagnosticFiles) {
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
                    throw new Error("Could not prune excess transition diagnostics");
                }
            }
            removed += 1;
        }
    }
}

async function writeSnapshotAtomically(
    path,
    snapshot,
    description = "HUD signal snapshot"
) {
    const serialized = JSON.stringify(snapshot);
    if (Buffer.byteLength(serialized, "utf8") > MAX_STATE_BYTES) {
        throw new Error(`${description} exceeded its configured size bound`);
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
        for (let attempt = 0; attempt < MAX_RENAME_ATTEMPTS; attempt += 1) {
            try {
                await rename(temporaryPath, path);
                renamed = true;
                break;
            } catch (error) {
                const retryable = process.platform === "win32" &&
                    TRANSIENT_RENAME_ERRORS.has(error?.code);
                if (!retryable || attempt === MAX_RENAME_ATTEMPTS - 1) {
                    const errorCode = typeof error?.code === "string" &&
                        /^[A-Z0-9_]{1,32}$/.test(error.code)
                        ? error.code
                        : "unknown";
                    throw new Error(
                        `Could not atomically replace the ${description} ` +
                        `(code=${errorCode}, attempts=${attempt + 1})`
                    );
                }
                const delayMs = Math.min(
                    RENAME_RETRY_MAX_MS,
                    RENAME_RETRY_BASE_MS * (attempt + 1)
                );
                await new Promise((resolve) => setTimeout(resolve, delayMs));
            }
        }
        if (!renamed) {
            throw new Error(`Could not atomically replace the ${description}`);
        }
        temporaryMayExist = false;
    } finally {
        if (temporaryMayExist) {
            try {
                await unlink(temporaryPath);
            } catch (error) {
                if (error?.code !== "ENOENT") {
                    throw new Error(
                        `Could not remove an incomplete ${description}`
                    );
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

async function readDiagnosticRecords(path) {
    let contents;
    try {
        contents = await readFile(path, "utf8");
    } catch (error) {
        if (error?.code === "ENOENT") {
            return [];
        }
        throw new Error("Could not read the transition diagnostic");
    }
    if (Buffer.byteLength(contents, "utf8") > MAX_STATE_BYTES) {
        throw new Error("The transition diagnostic exceeded its size bound");
    }

    let parsed;
    try {
        parsed = JSON.parse(contents);
    } catch {
        throw new Error("The transition diagnostic is malformed");
    }
    if (!Array.isArray(parsed) || parsed.length > MAX_DIAGNOSTIC_RECORDS) {
        throw new Error("The transition diagnostic has an invalid record list");
    }
    return parsed.map(validateTransition);
}

export async function createSubagentTransitionStore(copilotHome, sessionId) {
    if (typeof copilotHome !== "string" || !isAbsolute(copilotHome) ||
        typeof sessionId !== "string" || !SESSION_ID_PATTERN.test(sessionId)) {
        throw new TypeError("A disposable COPILOT_HOME and safe session ID are required");
    }
    if (process.platform === "win32" &&
        !/^[A-Za-z]:[\\/]/.test(copilotHome)) {
        throw new TypeError("COPILOT_HOME must be on a local Windows drive");
    }
    if (!(await isDisposableCopilotHome(copilotHome))) {
        throw new Error("Transition diagnostics are restricted to a disposable temporary COPILOT_HOME");
    }

    const homePath = resolve(copilotHome);
    const realHome = await realpath(homePath);
    const directory = resolve(homePath, "state", "hud-signal-diagnostics");
    if (!isWithin(homePath, directory)) {
        throw new Error("Transition diagnostics must remain inside COPILOT_HOME");
    }

    await mkdir(directory, { recursive: true, mode: 0o700 });
    const directoryInfo = await lstat(directory);
    const realDirectory = await realpath(directory);
    if (!directoryInfo.isDirectory() ||
        directoryInfo.isSymbolicLink() ||
        !isWithin(realHome, realDirectory)) {
        throw new Error("Transition diagnostics are not in private local storage");
    }

    const path = join(
        directory,
        `hud-subagent-count-changes-${sessionId}.json`
    );
    await pruneDiagnosticDirectory(directory, path);

    let writeTail = Promise.resolve();
    return {
        append(transitions) {
            if (!Array.isArray(transitions) ||
                transitions.length > MAX_DIAGNOSTIC_RECORDS) {
                throw new Error("The transition diagnostic batch is outside its bound");
            }
            const safeTransitions = transitions.map(validateTransition);
            if (safeTransitions.length === 0) {
                return Promise.resolve();
            }

            const write = writeTail.then(async () => {
                const previous = await readDiagnosticRecords(path);
                const records = [...previous, ...safeTransitions]
                    .slice(-MAX_DIAGNOSTIC_RECORDS);
                while (records.length > 0 &&
                    Buffer.byteLength(JSON.stringify(records), "utf8") > MAX_STATE_BYTES) {
                    records.shift();
                }
                if (records.length === 0) {
                    throw new Error("The transition diagnostic exceeded its configured size bound");
                }
                await writeSnapshotAtomically(path, records);
            });
            writeTail = write.catch(() => undefined);
            return write;
        },
    };
}

export async function createAicValidationStore(copilotHome) {
    if (typeof copilotHome !== "string" || !isAbsolute(copilotHome)) {
        throw new TypeError("An absolute disposable COPILOT_HOME is required");
    }
    if (process.platform === "win32" &&
        !/^[A-Za-z]:[\\/]/.test(copilotHome)) {
        throw new TypeError("COPILOT_HOME must be on a local Windows drive");
    }
    if (!(await isDisposableCopilotHome(copilotHome))) {
        throw new Error("AIC validation is restricted to a disposable temporary COPILOT_HOME");
    }

    const homePath = resolve(copilotHome);
    const realHome = await realpath(homePath);
    const directory = resolve(homePath, "state", "hud-aic-validation");
    if (!isWithin(homePath, directory)) {
        throw new Error("AIC validation must remain inside COPILOT_HOME");
    }

    await mkdir(directory, { recursive: true, mode: 0o700 });
    const directoryInfo = await lstat(directory);
    const realDirectory = await realpath(directory);
    if (!directoryInfo.isDirectory() ||
        directoryInfo.isSymbolicLink() ||
        !isWithin(realHome, realDirectory)) {
        throw new Error("AIC validation is not in private local storage");
    }

    const path = join(directory, "validation.json");
    let existingValidation = false;
    try {
        await lstat(path);
        existingValidation = true;
    } catch (error) {
        if (error?.code !== "ENOENT") {
            throw new Error("Could not verify a fresh AIC validation home");
        }
    }
    if (existingValidation) {
        throw new Error(
            "AIC validation requires a fresh, single-session COPILOT_HOME"
        );
    }

    try {
        await writeFile(join(directory, "validation.lock"), "", {
            flag: "wx",
            mode: 0o600,
        });
    } catch (error) {
        if (error?.code === "EEXIST") {
            throw new Error(
                "AIC validation requires a fresh, single-session COPILOT_HOME"
            );
        }
        throw new Error("Could not reserve the disposable AIC validation home");
    }

    let writeTail = Promise.resolve();
    return {
        write(value) {
            const record = validateAicValidation(value);
            const write = writeTail.then(() =>
                writeSnapshotAtomically(
                    path,
                    record,
                    "AIC validation record"
                )
            );
            writeTail = write.catch(() => undefined);
            return write;
        },
    };
}

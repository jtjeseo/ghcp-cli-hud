import assert from "node:assert/strict";
import test from "node:test";
import {
    mkdtemp,
    mkdir,
    readFile,
    readdir,
    rm,
    writeFile,
} from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createSignalMachine } from "../.github/extensions/hud-signal-bridge/state-machine.mjs";
import {
    createAicValidationStore,
    createSignalStateStore,
    createSubagentTransitionStore,
    isDisposableCopilotHome,
} from "../.github/extensions/hud-signal-bridge/state-store.mjs";

function snapshot(
    sessionId,
    updatedAtMs,
    recentIncreaseNanoAiu = null,
    activeSubagentCount = null,
) {
    return {
        version: 1,
        sessionId,
        updatedAtMs,
        phase: recentIncreaseNanoAiu === null ? "idle" : "complete",
        phaseAtMs: updatedAtMs,
        recentIncreaseNanoAiu,
        recentAtMs: recentIncreaseNanoAiu === null ? null : updatedAtMs,
        recentSuppressedReason: null,
        activeSubagentCount,
    };
}

function aicValidationRecord(overrides = {}) {
    return {
        version: 1,
        validity: "valid",
        reason: "valid",
        baselineNanoAiu: 1_000_000_000,
        finalCheckpointNanoAiu: 7_390_000_000,
        computedDifferenceNanoAiu: 6_390_000_000,
        displayedIncreaseNanoAiu: 6_390_000_000,
        eventOrder: {
            bridgeSessionMatched: true,
            baselineBeforeInterval: true,
            rootTurnsStarted: 1,
            rootTurnsEnded: 1,
            rootTurnCountCapped: false,
            rootTurnsClosed: true,
            finalCheckpointAccepted: true,
            finalCheckpointAfterTurnEnd: true,
            idleAfterFinalCheckpoint: true,
            toolCallsClosed: true,
            overlapObserved: false,
            interruptionObserved: false,
            resetObserved: false,
            counterResetObserved: false,
            unverifiedSubagentActivity: false,
        },
        ...overrides,
    };
}

test("writes only bounded, allowlisted, session-scoped derived state", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-state-store-"));
    try {
        const sessionId = "store-fixture";
        const store = await createSignalStateStore(home, sessionId);
        const value = snapshot(sessionId, Date.now(), 39_907_500, 2);
        await store.write(value);

        const directory = join(home, "state", "hud-signal-bridge");
        const path = join(directory, `hud-signal-${sessionId}.json`);
        const contents = await readFile(path, "utf8");
        const parsed = JSON.parse(contents);
        assert.deepEqual(parsed, value);
        assert.ok(Buffer.byteLength(contents, "utf8") <= 4096);
        assert.deepEqual(Object.keys(parsed).sort(), [
            "activeSubagentCount",
            "phase",
            "phaseAtMs",
            "recentAtMs",
            "recentIncreaseNanoAiu",
            "recentSuppressedReason",
            "sessionId",
            "updatedAtMs",
            "version",
        ]);

        assert.throws(
            () => store.write({ ...value, prompt: "not permitted" }),
            /unapproved fields/
        );
        assert.throws(
            () => store.write({ ...value, activeSubagentCount: 17 }),
            /invalid active subagent count/
        );
        assert.throws(
            () => store.write({ ...value, recentSuppressedReason: "overlap" }),
            /invalid checkpoint difference/
        );
        const suppressed = {
            ...value,
            recentIncreaseNanoAiu: null,
            recentSuppressedReason: "overlap",
        };
        await store.write(suppressed);
        assert.deepEqual(JSON.parse(await readFile(path, "utf8")), suppressed);
        assert.throws(
            () => store.write({ ...suppressed, recentSuppressedReason: "free text" }),
            /invalid suppression reason/
        );
        assert.throws(
            () => store.write({ ...suppressed, recentAtMs: null }),
            /invalid suppression reason/
        );
        assert.equal((await readFile(path, "utf8")).includes("not permitted"), false);
        assert.deepEqual(await readdir(directory), [`hud-signal-${sessionId}.json`]);
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("writes one bounded AIC validation record without a session identifier", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-aic-validation-"));
    try {
        assert.equal(await isDisposableCopilotHome(home), true);
        const store = await createAicValidationStore(home);
        await assert.rejects(
            createAicValidationStore(home),
            /fresh, single-session/
        );
        const valid = aicValidationRecord();
        await store.write(valid);

        const directory = join(home, "state", "hud-aic-validation");
        const path = join(directory, "validation.json");
        const contents = await readFile(path, "utf8");
        assert.deepEqual(JSON.parse(contents), valid);
        assert.ok(Buffer.byteLength(contents, "utf8") <= 4096);
        assert.deepEqual((await readdir(directory)).sort(), [
            "validation.json",
            "validation.lock",
        ]);
        assert.equal(contents.includes("sessionId"), false);
        assert.equal(contents.includes(home), false);

        const replacement = {
            ...valid,
            baselineNanoAiu: 10,
            finalCheckpointNanoAiu: 27,
            computedDifferenceNanoAiu: 17,
            displayedIncreaseNanoAiu: 17,
        };
        await store.write(replacement);
        assert.deepEqual(JSON.parse(await readFile(path, "utf8")), replacement);
        assert.equal((await readdir(directory)).length, 2);
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("rejects ambiguous, inconsistent, or unapproved AIC validation fields", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-aic-validation-guard-"));
    try {
        const store = await createAicValidationStore(home);
        const valid = aicValidationRecord();
        assert.throws(
            () => store.write({ ...valid, sessionId: "must-not-be-stored" }),
            /unapproved fields/
        );
        assert.throws(
            () => store.write({
                ...valid,
                computedDifferenceNanoAiu: 6_389_999_999,
            }),
            /does not match its totals/
        );
        assert.throws(
            () => store.write({
                ...valid,
                eventOrder: {
                    ...valid.eventOrder,
                    overlapObserved: true,
                },
            }),
            /ambiguous boundaries or arithmetic/
        );
        assert.throws(
            () => store.write({
                ...valid,
                validity: "suppressed",
                reason: "interruption",
            }),
            /contains a displayable increase/
        );
        assert.equal(
            await readFile(
                join(home, "state", "hud-aic-validation", "validation.json"),
                "utf8"
            ).then(() => true, () => false),
            false
        );
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("reports a sanitized AIC validation atomic-replacement failure", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-aic-rename-failure-"));
    try {
        const store = await createAicValidationStore(home);
        const directory = join(home, "state", "hud-aic-validation");
        await mkdir(join(directory, "validation.json"));

        await assert.rejects(
            store.write(aicValidationRecord()),
            (error) => {
                assert.match(
                    error.message,
                    /^Could not atomically replace the AIC validation record \(code=(?:[A-Z0-9_]{1,32}|unknown), attempts=(?:[1-9]|1[0-2])\)$/
                );
                assert.equal(error.message.includes(home), false);
                return true;
            }
        );
        assert.deepEqual((await readdir(directory)).sort(), [
            "validation.json",
            "validation.lock",
        ]);
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("keeps concurrent session snapshots in separate files", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-state-sessions-"));
    try {
        const firstId = "concurrent-session-a";
        const secondId = "concurrent-session-b";
        const firstStore = await createSignalStateStore(home, firstId);
        const secondStore = await createSignalStateStore(home, secondId);
        const first = snapshot(firstId, Date.now(), null, 2);
        const second = snapshot(secondId, Date.now() + 1, null, 1);

        await Promise.all([firstStore.write(first), secondStore.write(second)]);

        const directory = join(home, "state", "hud-signal-bridge");
        const firstSaved = JSON.parse(await readFile(
            join(directory, `hud-signal-${firstId}.json`),
            "utf8"
        ));
        const secondSaved = JSON.parse(await readFile(
            join(directory, `hud-signal-${secondId}.json`),
            "utf8"
        ));
        assert.deepEqual(firstSaved, first);
        assert.deepEqual(secondSaved, second);
        assert.equal((await readdir(directory)).length, 2);
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("serializes atomic replacements into complete snapshots", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-state-atomic-"));
    try {
        const sessionId = "atomic-fixture";
        const store = await createSignalStateStore(home, sessionId);
        const directory = join(home, "state", "hud-signal-bridge");
        const path = join(directory, `hud-signal-${sessionId}.json`);
        await store.write(snapshot(sessionId, Date.now(), 1));

        await Promise.all(
            Array.from({ length: 40 }, (_, index) =>
                store.write(snapshot(sessionId, Date.now() + index, index + 1))
            )
        );

        const finalText = await readFile(path, "utf8");
        const finalState = JSON.parse(finalText);
        assert.ok(Buffer.byteLength(finalText, "utf8") <= 4096);
        assert.equal(finalState.recentIncreaseNanoAiu, 40);
        assert.deepEqual(await readdir(directory), [`hud-signal-${sessionId}.json`]);
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("caps the number of retained per-session state files", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-state-retention-"));
    try {
        const directory = join(home, "state", "hud-signal-bridge");
        const now = Date.now();
        await mkdir(directory, { recursive: true });
        for (let index = 0; index < 66; index += 1) {
            await writeFile(
                join(directory, `hud-signal-old-${index}.json`),
                JSON.stringify(snapshot(`old-${index}`, now))
            );
        }

        const store = await createSignalStateStore(home, "retention-current");
        await store.write(snapshot("retention-current", now + 1));
        const retained = await readdir(directory);
        assert.equal(retained.length, 64);
        assert.ok(retained.includes("hud-signal-retention-current.json"));
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("rejects non-local or mismatched state destinations", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-state-validation-"));
    try {
        const store = await createSignalStateStore(home, "matching-session");
        assert.throws(
            () => store.write(snapshot("different-session", Date.now())),
            /identity or timestamp/
        );
        await assert.rejects(
            createSignalStateStore(home, "../bad-session"),
            /absolute COPILOT_HOME and safe session ID/
        );
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("writes a bounded, sanitized per-session transition diagnostic", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-transition-store-"));
    try {
        assert.equal(await isDisposableCopilotHome(home), true);
        const sessionId = "diagnostic-session";
        const store = await createSubagentTransitionStore(home, sessionId);
        for (let index = 0; index < 40; index += 1) {
            await store.append([{
                atMs: 1_000 + index,
                reason: index % 2 === 0 ? "matched-start" : "matching-terminal",
                previousCount: index % 2 === 0 ? null : 1,
                nextCount: index % 2 === 0 ? 1 : 0,
            }]);
        }

        const directory = join(home, "state", "hud-signal-diagnostics");
        const path = join(
            directory,
            `hud-subagent-count-changes-${sessionId}.json`
        );
        const contents = await readFile(path, "utf8");
        const records = JSON.parse(contents);
        assert.equal(records.length, 32);
        assert.ok(Buffer.byteLength(contents, "utf8") <= 4096);
        assert.deepEqual(Object.keys(records[0]).sort(), [
            "atMs",
            "nextCount",
            "previousCount",
            "reason",
        ]);
        assert.equal(contents.includes("agent-private"), false);
        assert.equal(contents.includes("call-private"), false);
        assert.deepEqual(
            records.at(-1),
            {
                atMs: 1_039,
                reason: "matching-terminal",
                previousCount: 1,
                nextCount: 0,
            }
        );
        assert.throws(
            () => store.append([{
                atMs: 2_000,
                reason: "matching-terminal",
                previousCount: 1,
                nextCount: 0,
                toolCallId: "must-not-be-stored",
            }]),
            /unapproved fields/
        );
        assert.equal(contents.includes("must-not-be-stored"), false);
        assert.deepEqual(await readdir(directory), [
            `hud-subagent-count-changes-${sessionId}.json`,
        ]);
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("fits the maximum diagnostic record count under the 4 KiB bound", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-transition-byte-bound-"));
    try {
        const sessionId = "diagnostic-byte-bound";
        const store = await createSubagentTransitionStore(home, sessionId);
        const records = Array.from({ length: 32 }, (_, index) => ({
            atMs: Number.MAX_SAFE_INTEGER - index,
            reason: "session-idle-open-agent",
            previousCount: 16,
            nextCount: null,
        }));
        await store.append(records);

        const path = join(
            home,
            "state",
            "hud-signal-diagnostics",
            `hud-subagent-count-changes-${sessionId}.json`
        );
        const contents = await readFile(path, "utf8");
        assert.equal(JSON.parse(contents).length, 32);
        assert.ok(Buffer.byteLength(contents, "utf8") <= 4096);
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("persists machine transitions without event or agent identifiers", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-transition-integration-"));
    try {
        const sessionId = "diagnostic-integration";
        const startAt = 4_000;
        const machine = createSignalMachine(sessionId, startAt, {
            recordSubagentTransitions: true,
        });
        machine.observe({
            id: "private-event-start",
            type: "subagent.started",
            timestamp: new Date(startAt + 1).toISOString(),
            agentId: "private-agent-name",
            data: { toolCallId: "private-spawning-call" },
        });
        machine.observe({
            id: "private-event-terminal",
            type: "subagent.completed",
            timestamp: new Date(startAt + 2).toISOString(),
            agentId: "private-agent-name",
            data: { toolCallId: "private-spawning-call" },
        });

        const store = await createSubagentTransitionStore(home, sessionId);
        await store.append(machine.drainSubagentDiagnostics());
        const path = join(
            home,
            "state",
            "hud-signal-diagnostics",
            `hud-subagent-count-changes-${sessionId}.json`
        );
        const contents = await readFile(path, "utf8");
        assert.deepEqual(JSON.parse(contents), [
            {
                atMs: startAt + 1,
                reason: "matched-start",
                previousCount: null,
                nextCount: 1,
            },
            {
                atMs: startAt + 2,
                reason: "matching-terminal",
                previousCount: 1,
                nextCount: 0,
            },
        ]);
        for (const privateValue of [
            "private-event-start",
            "private-event-terminal",
            "private-agent-name",
            "private-spawning-call",
            sessionId,
        ]) {
            assert.equal(contents.includes(privateValue), false);
        }
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("stores same-count tool diagnostics with categorical context only", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-tool-diagnostic-store-"));
    try {
        const sessionId = "tool-diagnostic-session";
        const store = await createSubagentTransitionStore(home, sessionId);
        const diagnostic = {
            atMs: 4_500,
            reason: "tool-start-root-turn-closed",
            previousCount: 2,
            nextCount: 2,
            rootInterval: "closed",
            caller: "subagent",
            parentCorrelation: "matched",
        };
        await store.append([diagnostic]);

        const path = join(
            home,
            "state",
            "hud-signal-diagnostics",
            `hud-subagent-count-changes-${sessionId}.json`
        );
        const contents = await readFile(path, "utf8");
        assert.deepEqual(JSON.parse(contents), [diagnostic]);
        assert.deepEqual(Object.keys(JSON.parse(contents)[0]).sort(), [
            "atMs",
            "caller",
            "nextCount",
            "parentCorrelation",
            "previousCount",
            "reason",
            "rootInterval",
        ]);
        assert.equal(contents.includes(sessionId), false);
        assert.throws(
            () => store.append([{
                ...diagnostic,
                parentToolCallRef: "must-not-be-stored",
            }]),
            /unapproved fields/
        );
        assert.equal(contents.includes("must-not-be-stored"), false);
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("bounds categorical tool diagnostic records to 4 KiB", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-tool-diagnostic-bound-"));
    try {
        const sessionId = "tool-diagnostic-byte-bound";
        const store = await createSubagentTransitionStore(home, sessionId);
        const records = Array.from({ length: 32 }, (_, index) => ({
            atMs: Number.MAX_SAFE_INTEGER - index,
            reason: "tool-complete-unmatched-call-id",
            previousCount: 16,
            nextCount: 16,
            rootInterval: "closed",
            caller: "subagent",
            parentCorrelation: "unmatched",
        }));
        await store.append(records);

        const path = join(
            home,
            "state",
            "hud-signal-diagnostics",
            `hud-subagent-count-changes-${sessionId}.json`
        );
        const contents = await readFile(path, "utf8");
        const parsed = JSON.parse(contents);
        assert.ok(parsed.length > 0);
        assert.ok(parsed.length <= 32);
        assert.equal(parsed.at(-1).atMs, Number.MAX_SAFE_INTEGER - 31);
        assert.ok(Buffer.byteLength(contents, "utf8") <= 4096);
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("keeps transition diagnostics session-scoped and refuses the normal Copilot home", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-transition-sessions-"));
    try {
        const firstId = "diagnostic-session-a";
        const secondId = "diagnostic-session-b";
        const firstStore = await createSubagentTransitionStore(home, firstId);
        const secondStore = await createSubagentTransitionStore(home, secondId);
        await Promise.all([
            firstStore.append([{
                atMs: 3_001,
                reason: "matched-start",
                previousCount: null,
                nextCount: 1,
            }]),
            secondStore.append([{
                atMs: 3_002,
                reason: "matched-start",
                previousCount: null,
                nextCount: 1,
            }]),
        ]);

        const directory = join(home, "state", "hud-signal-diagnostics");
        assert.deepEqual(
            JSON.parse(await readFile(
                join(directory, `hud-subagent-count-changes-${firstId}.json`),
                "utf8"
            )),
            [{
                atMs: 3_001,
                reason: "matched-start",
                previousCount: null,
                nextCount: 1,
            }]
        );
        assert.deepEqual(
            JSON.parse(await readFile(
                join(directory, `hud-subagent-count-changes-${secondId}.json`),
                "utf8"
            )),
            [{
                atMs: 3_002,
                reason: "matched-start",
                previousCount: null,
                nextCount: 1,
            }]
        );
        assert.equal((await readdir(directory)).length, 2);

        const normalHome = resolve(
            process.env.USERPROFILE || homedir(),
            ".copilot"
        );
        assert.equal(await isDisposableCopilotHome(normalHome), false);
        await assert.rejects(
            createSubagentTransitionStore(normalHome, "normal-session"),
            /restricted to a disposable/
        );

        const originalProfile = process.env.USERPROFILE;
        const syntheticProfile = join(home, "synthetic-profile");
        const syntheticNormalHome = join(syntheticProfile, ".copilot");
        const nestedHome = join(syntheticNormalHome, "nested-home");
        await mkdir(nestedHome, { recursive: true });
        process.env.USERPROFILE = syntheticProfile;
        try {
            assert.equal(
                await isDisposableCopilotHome(syntheticNormalHome),
                false
            );
            assert.equal(await isDisposableCopilotHome(nestedHome), false);
        } finally {
            if (originalProfile === undefined) {
                delete process.env.USERPROFILE;
            } else {
                process.env.USERPROFILE = originalProfile;
            }
        }
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("caps the number of retained transition diagnostic files", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-transition-retention-"));
    try {
        const directory = join(home, "state", "hud-signal-diagnostics");
        const now = Date.now();
        await mkdir(directory, { recursive: true });
        for (let index = 0; index < 66; index += 1) {
            await writeFile(
                join(directory, `hud-subagent-count-changes-old-${index}.json`),
                "[]"
            );
        }

        const store = await createSubagentTransitionStore(home, "retention-current");
        await store.append([{
            atMs: now,
            reason: "matched-start",
            previousCount: null,
            nextCount: 1,
        }]);
        const retained = await readdir(directory);
        assert.equal(retained.length, 64);
        assert.ok(retained.includes(
            "hud-subagent-count-changes-retention-current.json"
        ));
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

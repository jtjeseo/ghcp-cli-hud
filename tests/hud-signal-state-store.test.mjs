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
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createSignalStateStore } from "../.github/extensions/hud-signal-bridge/state-store.mjs";

function snapshot(sessionId, updatedAtMs, recentIncreaseNanoAiu = null) {
    return {
        version: 1,
        sessionId,
        updatedAtMs,
        phase: recentIncreaseNanoAiu === null ? "idle" : "complete",
        phaseAtMs: updatedAtMs,
        recentIncreaseNanoAiu,
        recentAtMs: recentIncreaseNanoAiu === null ? null : updatedAtMs,
    };
}

test("writes only bounded, allowlisted, session-scoped derived state", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-state-store-"));
    try {
        const sessionId = "store-fixture";
        const store = await createSignalStateStore(home, sessionId);
        const value = snapshot(sessionId, Date.now(), 39_907_500);
        await store.write(value);

        const directory = join(home, "state", "hud-signal-bridge");
        const path = join(directory, `hud-signal-${sessionId}.json`);
        const contents = await readFile(path, "utf8");
        const parsed = JSON.parse(contents);
        assert.deepEqual(parsed, value);
        assert.ok(Buffer.byteLength(contents, "utf8") <= 4096);
        assert.deepEqual(Object.keys(parsed).sort(), [
            "phase",
            "phaseAtMs",
            "recentAtMs",
            "recentIncreaseNanoAiu",
            "sessionId",
            "updatedAtMs",
            "version",
        ]);

        assert.throws(
            () => store.write({ ...value, prompt: "not permitted" }),
            /unapproved fields/
        );
        assert.equal((await readFile(path, "utf8")).includes("not permitted"), false);
        assert.deepEqual(await readdir(directory), [`hud-signal-${sessionId}.json`]);
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

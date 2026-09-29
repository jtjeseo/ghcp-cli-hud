import assert from "node:assert/strict";
import test from "node:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createSignalStateStore } from "../.github/extensions/hud-signal-bridge/state-store.mjs";

test("reports a sanitized native code when snapshot replacement fails", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-rename-failure-"));
    const sessionId = "rename-failure-session";
    try {
        const store = await createSignalStateStore(home, sessionId);
        const targetPath = join(
            home,
            "state",
            "hud-signal-bridge",
            `hud-signal-${sessionId}.json`
        );
        await mkdir(targetPath);

        await assert.rejects(
            store.write({
                version: 1,
                sessionId,
                updatedAtMs: 1,
                phase: "working",
                phaseAtMs: 1,
                recentIncreaseNanoAiu: null,
                recentAtMs: null,
                activeSubagentCount: null,
            }),
            (error) => {
                assert.match(
                    error.message,
                    /^Could not atomically replace the HUD signal snapshot \(code=(?:[A-Z0-9_]{1,32}|unknown), attempts=(?:[1-9]|1[0-2])\)$/
                );
                assert.equal(error.message.includes(home), false);
                assert.equal(error.message.includes(sessionId), false);
                return true;
            }
        );
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

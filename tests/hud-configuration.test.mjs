import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";
import { readHudOptIn, resolveBridgeConfiguration } from "../.github/extensions/hud-signal-bridge/configuration.mjs";

async function fixture(t) {
    const root = await mkdtemp(join(tmpdir(), "hud-config-"));
    t.after(() => rm(root, { recursive: true, force: true }));
    return root;
}
test("installed bridge uses its own explicit opt-in without user environment edits", async (t) => {
    const home = await fixture(t);
    await writeFile(join(home, "hud-signal-bridge.json"), '{"version":1,"enabled":true}');
    const url = pathToFileURL(join(home, "extensions", "hud-signal-bridge", "extension.mjs"));
    assert.deepEqual(await resolveBridgeConfiguration(url, {}), { home, enabled: true });
    assert.deepEqual(await resolveBridgeConfiguration(url, { COPILOT_HUD_SIGNAL_BRIDGE: "0" }),
        { home, enabled: false });
});
test("project discovery never enables the bridge through installed-config inference", async (t) => {
    const root = await fixture(t);
    const home = join(root, ".github");
    await mkdir(home);
    await writeFile(join(home, "hud-signal-bridge.json"), '{"version":1,"enabled":true}');
    const url = pathToFileURL(join(home, "extensions", "hud-signal-bridge", "extension.mjs"));
    assert.deepEqual(await resolveBridgeConfiguration(url, {}), { home: null, enabled: false });
    assert.deepEqual(await resolveBridgeConfiguration(url, {
        COPILOT_HOME: root, COPILOT_HUD_SIGNAL_BRIDGE: "1",
    }), { home: root, enabled: true });
    assert.equal((await resolveBridgeConfiguration(url, { COPILOT_HOME: root })).enabled, false);
});
test("another explicit home does not inherit the installed home's opt-in", async (t) => {
    const home = await fixture(t);
    const other = join(home, "other");
    await writeFile(join(home, "hud-signal-bridge.json"), '{"version":1,"enabled":true}');
    const url = pathToFileURL(join(home, "extensions", "hud-signal-bridge", "extension.mjs"));
    assert.equal((await resolveBridgeConfiguration(url, { COPILOT_HOME: other })).enabled, false);
    await assert.rejects(resolveBridgeConfiguration(url, { COPILOT_HOME: "relative" }));
});
test("missing and disabled options stay inert; malformed options fail explicitly", async (t) => {
    const home = await fixture(t);
    const name = "hud-signal-bridge.json";
    assert.equal(await readHudOptIn(home, name), false);
    await writeFile(join(home, name), '{"version":1,"enabled":false}');
    assert.equal(await readHudOptIn(home, name), false);
    for (const text of ['null', '[]', '{bad', '{"version":true,"enabled":true}',
        '{"version":1,"enabled":true,"extra":1}', "x".repeat(257)]) {
        await writeFile(join(home, name), text);
        await assert.rejects(readHudOptIn(home, name));
    }
    await writeFile(join(home, name), Buffer.from([0xff, 0xfe]));
    await assert.rejects(readHudOptIn(home, name));
});

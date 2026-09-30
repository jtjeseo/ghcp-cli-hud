import { open } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export async function readHudOptIn(home, name) {
    let handle;
    try {
        handle = await open(join(home, name), "r");
        const stat = await handle.stat();
        if (!stat.isFile() || stat.size <= 0 || stat.size > 256) {
            throw new Error("invalid-options");
        }
        const bytes = Buffer.alloc(stat.size);
        let offset = 0;
        while (offset < bytes.length) {
            const { bytesRead } = await handle.read(bytes, offset, bytes.length - offset, offset);
            if (bytesRead === 0) { throw new Error("incomplete-options"); }
            offset += bytesRead;
        }
        const options = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
        if (options === null || typeof options !== "object" || Array.isArray(options) ||
            Object.keys(options).length !== 2 || options.version !== 1 ||
            typeof options.enabled !== "boolean") { throw new Error("invalid-options"); }
        return options.enabled;
    } catch (error) {
        if (error.code === "ENOENT") { return false; }
        throw error;
    } finally {
        await handle?.close();
    }
}

export async function resolveBridgeConfiguration(moduleUrl, env = process.env) {
    const directory = dirname(fileURLToPath(moduleUrl));
    const parent = dirname(dirname(directory));
    const installedHome = basename(directory) === "hud-signal-bridge" &&
        basename(dirname(directory)) === "extensions" && basename(parent) !== ".github" ? parent : null;
    const explicitHome = typeof env.COPILOT_HOME === "string" && env.COPILOT_HOME.length > 0
        ? env.COPILOT_HOME : null;
    if (explicitHome !== null && !isAbsolute(explicitHome)) { throw new Error("invalid-home"); }
    const home = explicitHome === null ? installedHome : resolve(explicitHome);
    const optIn = env.COPILOT_HUD_SIGNAL_BRIDGE;
    if (typeof optIn === "string" && optIn.length > 0) {
        return { home, enabled: home !== null && optIn === "1" };
    }
    const sameInstallation = home !== null && installedHome !== null &&
        (process.platform === "win32"
            ? home.toLowerCase() === installedHome.toLowerCase() : home === installedHome);
    return {
        home,
        enabled: sameInstallation && await readHudOptIn(home, "hud-signal-bridge.json"),
    };
}

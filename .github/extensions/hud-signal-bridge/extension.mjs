import { joinSession } from "@github/copilot-sdk/extension";
import { createSignalMachine } from "./state-machine.mjs";
import { createSignalStateStore } from "./state-store.mjs";

const OPT_IN = "COPILOT_HUD_SIGNAL_BRIDGE";
const HEARTBEAT_MS = 5000;

function safeSessionId(value) {
    return typeof value === "string" &&
        value.length > 0 &&
        value.length <= 128 &&
        /^[A-Za-z0-9_-]+$/.test(value)
        ? value
        : null;
}

function reportOnce(message) {
    if (reportOnce.reported) {
        return;
    }
    reportOnce.reported = true;
    console.error(`[hud-signal-bridge] ${message}; HUD falls back to hook activity.`);
}
reportOnce.reported = false;

async function startBridge() {
    const sessionId = safeSessionId(process.env.SESSION_ID);
    const copilotHome = process.env.COPILOT_HOME;
    if (!sessionId || typeof copilotHome !== "string") {
        throw new Error("Isolated CLI session and COPILOT_HOME are required");
    }

    const store = await createSignalStateStore(copilotHome, sessionId);
    const session = await joinSession({ suppressResumeEvent: false });
    if (safeSessionId(session.sessionId) !== sessionId ||
        typeof session.on !== "function") {
        throw new Error("Observer did not attach to the CLI-provided session");
    }

    const machine = createSignalMachine(sessionId);
    let pendingSnapshot = null;
    let writeTask = null;

    function scheduleWrite() {
        pendingSnapshot = machine.snapshot();
        if (writeTask !== null) {
            return;
        }

        writeTask = (async () => {
            while (pendingSnapshot !== null) {
                const nextSnapshot = pendingSnapshot;
                pendingSnapshot = null;
                await store.write(nextSnapshot);
            }
        })()
            .catch(() => {
                pendingSnapshot = null;
                machine.reset();
                reportOnce("State update failed");
            })
            .finally(() => {
                writeTask = null;
                if (pendingSnapshot !== null) {
                    scheduleWrite();
                }
            });
    }

    session.on((event) => {
        try {
            if (machine.observe(event)) {
                scheduleWrite();
            }
        } catch {
            machine.reset();
            reportOnce("Event processing failed");
            scheduleWrite();
        }
    });

    scheduleWrite();
    const heartbeat = setInterval(() => {
        try {
            if (machine.heartbeat()) {
                scheduleWrite();
            }
        } catch {
            machine.reset();
            reportOnce("Heartbeat failed");
            scheduleWrite();
        }
    }, HEARTBEAT_MS);
    heartbeat.unref();
}

if (process.env[OPT_IN] === "1") {
    try {
        await startBridge();
    } catch {
        reportOnce("Initialization failed");
    }
}

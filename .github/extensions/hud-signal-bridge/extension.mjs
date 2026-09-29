import { joinSession } from "@github/copilot-sdk/extension";
import { createQuotaWriter } from "./quota.mjs";
import { createSignalMachine } from "./state-machine.mjs";
import {
    createAicValidationStore,
    createQuotaStateStore,
    createSignalStateStore,
    createSubagentTransitionStore,
    isDisposableCopilotHome,
} from "./state-store.mjs";

const OPT_IN = "COPILOT_HUD_SIGNAL_BRIDGE";
const DIAGNOSTICS_OPT_IN = "COPILOT_HUD_SIGNAL_DIAGNOSTICS";
const AIC_VALIDATION_OPT_IN = "COPILOT_HUD_AIC_VALIDATION";
const HEARTBEAT_MS = 5000;
const MAX_PENDING_DIAGNOSTICS = 32;

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
    console.error(
        `[hud-signal-bridge] ${message}; the renderer rejects state older than ` +
        "20 seconds and otherwise falls back to matching-session hook activity."
    );
}
reportOnce.reported = false;

function reportDiagnosticOnce(message) {
    if (reportDiagnosticOnce.reported) {
        return;
    }
    reportDiagnosticOnce.reported = true;
    console.error(`[hud-signal-bridge] ${message}; bridge remains active.`);
}
reportDiagnosticOnce.reported = false;

function reportAicValidationOnce(message) {
    if (reportAicValidationOnce.reported) {
        return;
    }
    reportAicValidationOnce.reported = true;
    console.error(`[hud-signal-bridge] ${message}; bridge remains active.`);
}
reportAicValidationOnce.reported = false;

function reportQuotaOnce(message) {
    if (reportQuotaOnce.reported) {
        return;
    }
    reportQuotaOnce.reported = true;
    try {
        console.error(`[hud-signal-bridge] ${message}; quota capture stopped.`);
    } catch {
        // A quota diagnostic must never affect the session listener.
    }
}
reportQuotaOnce.reported = false;

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

    let quotaWriter = null;
    try {
        const quotaStore = await createQuotaStateStore(copilotHome);
        quotaWriter = createQuotaWriter(quotaStore, () =>
            reportQuotaOnce("Account quota update failed")
        );
    } catch {
        reportQuotaOnce("Account quota storage could not be initialized");
    }

    let diagnosticStore = null;
    if (process.env[DIAGNOSTICS_OPT_IN] === "1") {
        try {
            if (await isDisposableCopilotHome(copilotHome)) {
                diagnosticStore = await createSubagentTransitionStore(
                    copilotHome,
                    sessionId
                );
            } else {
                reportDiagnosticOnce(
                    "Disposable-only transition diagnostics were ignored"
                );
            }
        } catch {
            reportDiagnosticOnce(
                "Bounded transition diagnostics could not be initialized"
            );
        }
    }

    let aicValidationStore = null;
    if (process.env[AIC_VALIDATION_OPT_IN] === "1") {
        try {
            if (await isDisposableCopilotHome(copilotHome)) {
                aicValidationStore = await createAicValidationStore(copilotHome);
            } else {
                reportAicValidationOnce(
                    "Disposable-only AIC validation was ignored"
                );
            }
        } catch {
            reportAicValidationOnce(
                "Bounded AIC validation could not be initialized"
            );
        }
    }

    const machine = createSignalMachine(sessionId, Date.now(), {
        recordSubagentTransitions: diagnosticStore !== null,
        recordAicValidation: aicValidationStore !== null,
        bridgeSessionMatched: aicValidationStore !== null,
    });
    let pendingSnapshot = null;
    let writeTask = null;
    let pendingDiagnostics = [];
    let diagnosticWriteActive = false;
    let pendingAicValidation = null;
    let aicValidationWriteActive = false;

    function scheduleDiagnosticWrite() {
        if (diagnosticStore === null) {
            return;
        }
        const diagnostics = machine.drainSubagentDiagnostics();
        if (diagnostics.length === 0) {
            if (diagnosticWriteActive || pendingDiagnostics.length === 0) {
                return;
            }
        } else {
            pendingDiagnostics.push(...diagnostics);
            if (pendingDiagnostics.length > MAX_PENDING_DIAGNOSTICS) {
                pendingDiagnostics.splice(
                    0,
                    pendingDiagnostics.length - MAX_PENDING_DIAGNOSTICS
                );
            }
        }

        if (diagnosticWriteActive || pendingDiagnostics.length === 0) {
            return;
        }
        const store = diagnosticStore;
        diagnosticWriteActive = true;
        void (async () => {
            try {
                while (pendingDiagnostics.length > 0 &&
                    diagnosticStore === store) {
                    const batch = pendingDiagnostics.splice(
                        0,
                        MAX_PENDING_DIAGNOSTICS
                    );
                    await store.append(batch);
                }
            } catch {
                pendingDiagnostics = [];
                diagnosticStore = null;
                reportDiagnosticOnce(
                    "Bounded transition diagnostics could not be written"
                );
            } finally {
                diagnosticWriteActive = false;
                if (pendingDiagnostics.length > 0 &&
                    diagnosticStore !== null) {
                    scheduleDiagnosticWrite();
                }
            }
        })();
    }

    function scheduleAicValidationWrite() {
        if (aicValidationStore === null) {
            return;
        }
        const validation = machine.drainAicValidation();
        if (validation !== null) {
            pendingAicValidation = validation;
        }
        if (aicValidationWriteActive || pendingAicValidation === null) {
            return;
        }

        const store = aicValidationStore;
        aicValidationWriteActive = true;
        void (async () => {
            try {
                while (pendingAicValidation !== null &&
                    aicValidationStore === store) {
                    const nextValidation = pendingAicValidation;
                    pendingAicValidation = null;
                    const snapshotWrite = writeTask;
                    if (snapshotWrite !== null) {
                        await snapshotWrite;
                    }
                    if (aicValidationStore !== store) {
                        break;
                    }
                    await store.write(nextValidation);
                }
            } catch {
                pendingAicValidation = null;
                aicValidationStore = null;
                reportAicValidationOnce(
                    "Bounded AIC validation could not be written"
                );
            } finally {
                aicValidationWriteActive = false;
                if (pendingAicValidation !== null &&
                    aicValidationStore !== null) {
                    scheduleAicValidationWrite();
                }
            }
        })();
    }

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
                scheduleDiagnosticWrite();
                pendingAicValidation = null;
                aicValidationStore = null;
                reportAicValidationOnce(
                    "AIC validation was disabled after a bridge write failure"
                );
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
        if (quotaWriter !== null) {
            try {
                quotaWriter(event);
            } catch {
                quotaWriter = null;
                reportQuotaOnce("Account quota event processing failed");
            }
        }
        try {
            const changed = machine.observe(event);
            scheduleDiagnosticWrite();
            if (changed) {
                scheduleWrite();
            }
            scheduleAicValidationWrite();
        } catch {
            machine.reset();
            scheduleDiagnosticWrite();
            reportOnce("Event processing failed");
            scheduleWrite();
            scheduleAicValidationWrite();
        }
    });

    scheduleWrite();
    const heartbeat = setInterval(() => {
        try {
            const changed = machine.heartbeat();
            scheduleDiagnosticWrite();
            if (changed) {
                scheduleWrite();
            }
            scheduleAicValidationWrite();
        } catch {
            machine.reset();
            scheduleDiagnosticWrite();
            reportOnce("Heartbeat failed");
            scheduleWrite();
            scheduleAicValidationWrite();
        }
    }, HEARTBEAT_MS);
    heartbeat.unref();
}

// Attach without listeners so the host sees a ready, idle extension instead of
// waiting for startup-timeout when the bridge is not opted in or cannot start.
async function attachIdle() {
    try {
        await joinSession({ suppressResumeEvent: true });
    } catch {
        // Host attachment is best-effort; the HUD falls back to hook state.
    }
}

if (process.env[OPT_IN] === "1") {
    try {
        await startBridge();
    } catch {
        reportOnce("Initialization failed");
        await attachIdle();
    }
} else {
    await attachIdle();
}

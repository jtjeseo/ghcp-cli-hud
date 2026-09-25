const SESSION_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const EVENT_ID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;
const NANO_AIU_LIMIT = Number.MAX_SAFE_INTEGER;
const RECENT_DELTA_TTL_MS = 120_000;
const COMPLETE_PHASE_TTL_MS = 10_000;
const MAX_SEEN_EVENT_IDS = 512;
const MAX_ACTIVE_TOOL_CALLS = 32;

const TRACKED_EVENTS = new Set([
    "assistant.idle",
    "assistant.intent",
    "assistant.turn_end",
    "assistant.turn_start",
    "assistant.usage",
    "permission.requested",
    "session.context_cleared",
    "session.idle",
    "session.resume",
    "session.start",
    "session.usage_checkpoint",
    "subagent.completed",
    "subagent.failed",
    "subagent.started",
    "tool.execution_complete",
    "tool.execution_progress",
    "tool.execution_start",
]);

function safeTimestamp(value) {
    if (
        typeof value !== "string" ||
        value.length > 40 ||
        !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(value)
    ) {
        return null;
    }

    const milliseconds = Date.parse(value);
    return Number.isFinite(milliseconds) ? milliseconds : null;
}

function safeInteger(value) {
    return Number.isSafeInteger(value) && value >= 0 && value <= NANO_AIU_LIMIT;
}

function safeId(value) {
    return typeof value === "string" &&
        value.length > 0 &&
        value.length <= 128 &&
        EVENT_ID_PATTERN.test(value)
        ? value
        : null;
}

function newInterval() {
    return {
        turnsStarted: 0,
        turnsEnded: 0,
        turnOpen: false,
        lastTurnEndMs: null,
        activeToolCalls: new Set(),
        pendingCheckpoint: null,
        ambiguous: false,
        sawTurn: false,
    };
}

export function createSignalMachine(sessionId, startedAtMs = Date.now()) {
    if (typeof sessionId !== "string" || !SESSION_ID_PATTERN.test(sessionId)) {
        throw new TypeError("A safe CLI session ID is required");
    }
    if (!safeInteger(startedAtMs)) {
        throw new TypeError("The initial timestamp must be a non-negative safe integer");
    }

    let baselineTotalNanoAiu = null;
    let pendingBaseline = null;
    let pendingBaselineAmbiguous = false;
    let lastTotalNanoAiu = null;
    let lastTimestampMs = null;
    let interval = null;
    let unverifiedSubagentActivity = false;
    const seenEventIds = new Set();
    const eventIdOrder = [];

    const output = {
        version: 1,
        sessionId,
        updatedAtMs: startedAtMs,
        phase: null,
        phaseAtMs: null,
        recentIncreaseNanoAiu: null,
        recentAtMs: null,
    };

    function clearRecent() {
        output.recentIncreaseNanoAiu = null;
        output.recentAtMs = null;
    }

    function setPhase(phase, timestampMs) {
        output.phase = phase;
        output.phaseAtMs = phase === null ? null : timestampMs;
        output.updatedAtMs = timestampMs;
    }

    function resetBoundary(timestampMs, phase = null) {
        baselineTotalNanoAiu = null;
        pendingBaseline = null;
        pendingBaselineAmbiguous = false;
        lastTotalNanoAiu = null;
        lastTimestampMs = timestampMs;
        interval = null;
        unverifiedSubagentActivity = false;
        seenEventIds.clear();
        eventIdOrder.length = 0;
        clearRecent();
        setPhase(phase, timestampMs);
    }

    function markAmbiguous(timestampMs, phase = null) {
        if (interval === null) {
            interval = newInterval();
        }
        interval.ambiguous = true;
        baselineTotalNanoAiu = null;
        pendingBaseline = null;
        pendingBaselineAmbiguous = false;
        clearRecent();
        setPhase(phase, timestampMs);
    }

    function rememberEventId(eventId) {
        if (eventId === null) {
            return false;
        }
        if (seenEventIds.has(eventId)) {
            return true;
        }
        seenEventIds.add(eventId);
        eventIdOrder.push(eventId);
        if (eventIdOrder.length > MAX_SEEN_EVENT_IDS) {
            seenEventIds.delete(eventIdOrder.shift());
        }
        return false;
    }

    function observe(event) {
        if (!event || typeof event !== "object" || typeof event.type !== "string") {
            return false;
        }

        if (/(?:interrupt|cancel|abort)/i.test(event.type)) {
            markAmbiguous(safeTimestamp(event.timestamp) ?? Date.now());
            return true;
        }
        if (!TRACKED_EVENTS.has(event.type)) {
            return false;
        }

        if (event.type === "session.start") {
            const startTime = safeTimestamp(event.timestamp) ?? Date.now();
            resetBoundary(startTime, "idle");
            return true;
        }
        if (event.type === "session.resume" ||
            event.type === "session.context_cleared") {
            const resetTime = safeTimestamp(event.timestamp) ?? Date.now();
            resetBoundary(resetTime);
            return true;
        }

        const timestampMs = safeTimestamp(event.timestamp);
        if (timestampMs === null) {
            markAmbiguous(Date.now());
            return true;
        }
        if (lastTimestampMs !== null && timestampMs < lastTimestampMs) {
            markAmbiguous(timestampMs);
            lastTimestampMs = Math.max(lastTimestampMs, timestampMs);
            return true;
        }
        lastTimestampMs = timestampMs;

        const eventId = safeId(event.id);
        if (eventId !== null && rememberEventId(eventId)) {
            return false;
        }
        const criticalEvent = event.type === "assistant.turn_start" ||
            event.type === "assistant.turn_end" ||
            event.type === "session.idle" ||
            event.type === "session.usage_checkpoint" ||
            event.type === "tool.execution_start" ||
            event.type === "tool.execution_complete" ||
            event.type === "tool.execution_progress";
        if (criticalEvent && eventId === null) {
            markAmbiguous(timestampMs);
        }

        if (event.type.startsWith("subagent.")) {
            unverifiedSubagentActivity = true;
            if (interval !== null) {
                interval.ambiguous = true;
            }
            baselineTotalNanoAiu = null;
            pendingBaseline = null;
            clearRecent();
            setPhase(output.phase, timestampMs);
            return true;
        }

        const data = event.data && typeof event.data === "object" &&
            !Array.isArray(event.data)
            ? event.data
            : {};

        switch (event.type) {
            case "assistant.turn_start": {
                if (pendingBaseline !== null) {
                    pendingBaseline = null;
                    pendingBaselineAmbiguous = false;
                    baselineTotalNanoAiu = null;
                    interval = newInterval();
                    interval.ambiguous = true;
                } else if (interval === null) {
                    interval = newInterval();
                    clearRecent();
                } else if (interval.pendingCheckpoint !== null) {
                    interval.ambiguous = true;
                    interval.pendingCheckpoint = null;
                }

                if (interval.turnOpen) {
                    interval.ambiguous = true;
                }
                interval.turnOpen = true;
                interval.turnsStarted += 1;
                interval.sawTurn = true;
                setPhase("working", timestampMs);
                return true;
            }

            case "assistant.turn_end": {
                if (interval === null || !interval.turnOpen) {
                    markAmbiguous(timestampMs);
                    return true;
                }
                if (interval.activeToolCalls.size > 0) {
                    interval.ambiguous = true;
                }
                interval.turnOpen = false;
                interval.turnsEnded += 1;
                interval.lastTurnEndMs = timestampMs;
                setPhase("working", timestampMs);
                return true;
            }

            case "tool.execution_start": {
                const toolCallId = safeId(data.toolCallId);
                if (interval === null || !interval.turnOpen ||
                    toolCallId === null ||
                    interval.activeToolCalls.size >= MAX_ACTIVE_TOOL_CALLS ||
                    interval.activeToolCalls.has(toolCallId)) {
                    markAmbiguous(timestampMs, "running-tool");
                    return true;
                }
                if (interval.activeToolCalls.size > 0) {
                    interval.ambiguous = true;
                }
                interval.activeToolCalls.add(toolCallId);
                setPhase("running-tool", timestampMs);
                return true;
            }

            case "tool.execution_progress": {
                const toolCallId = safeId(data.toolCallId);
                if (interval === null || toolCallId === null ||
                    !interval.activeToolCalls.has(toolCallId)) {
                    markAmbiguous(timestampMs);
                    return true;
                }
                setPhase("running-tool", timestampMs);
                return true;
            }

            case "tool.execution_complete": {
                const toolCallId = safeId(data.toolCallId);
                if (interval === null || toolCallId === null ||
                    !interval.activeToolCalls.has(toolCallId)) {
                    markAmbiguous(timestampMs);
                    return true;
                }
                interval.activeToolCalls.delete(toolCallId);
                setPhase("working", timestampMs);
                return true;
            }

            case "session.usage_checkpoint": {
                const total = data.totalNanoAiu;
                if (!safeInteger(total)) {
                    markAmbiguous(timestampMs);
                    lastTotalNanoAiu = null;
                    return true;
                }
                if (lastTotalNanoAiu !== null && total < lastTotalNanoAiu) {
                    baselineTotalNanoAiu = null;
                    pendingBaseline = null;
                    clearRecent();
                    if (interval !== null) {
                        interval.ambiguous = true;
                    }
                }
                lastTotalNanoAiu = total;

                const checkpoint = { total, timestampMs };
                if (interval === null) {
                    if (pendingBaseline !== null) {
                        pendingBaselineAmbiguous = true;
                    }
                    pendingBaseline = checkpoint;
                    output.updatedAtMs = timestampMs;
                    return true;
                }
                if (interval.pendingCheckpoint !== null) {
                    interval.ambiguous = true;
                }
                if (!interval.sawTurn || interval.turnOpen ||
                    interval.turnsStarted !== interval.turnsEnded ||
                    interval.activeToolCalls.size > 0) {
                    interval.ambiguous = true;
                }
                interval.pendingCheckpoint = checkpoint;
                output.updatedAtMs = timestampMs;
                return true;
            }

            case "session.idle": {
                if (interval === null) {
                    if (pendingBaseline !== null && !pendingBaselineAmbiguous) {
                        baselineTotalNanoAiu = pendingBaseline.total;
                    } else if (pendingBaselineAmbiguous) {
                        baselineTotalNanoAiu = null;
                    }
                    pendingBaseline = null;
                    pendingBaselineAmbiguous = false;
                    setPhase("idle", timestampMs);
                    return true;
                }

                const finalCheckpoint = interval.pendingCheckpoint;
                const turnsClosed = interval.sawTurn &&
                    interval.turnsStarted > 0 &&
                    interval.turnsStarted === interval.turnsEnded &&
                    !interval.turnOpen;
                const toolsClosed = interval.activeToolCalls.size === 0;
                const checkpointFollowsTurn = finalCheckpoint !== null &&
                    interval.turnsEnded > 0 &&
                    interval.lastTurnEndMs !== null &&
                    finalCheckpoint.timestampMs >= interval.lastTurnEndMs;
                const validInterval = !interval.ambiguous &&
                    !unverifiedSubagentActivity &&
                    turnsClosed &&
                    toolsClosed &&
                    checkpointFollowsTurn &&
                    finalCheckpoint !== null;

                if (validInterval &&
                    baselineTotalNanoAiu !== null &&
                    finalCheckpoint.total >= baselineTotalNanoAiu) {
                    output.recentIncreaseNanoAiu =
                        finalCheckpoint.total - baselineTotalNanoAiu;
                    output.recentAtMs = timestampMs;
                } else {
                    clearRecent();
                }

                baselineTotalNanoAiu = finalCheckpoint === null
                    ? null
                    : finalCheckpoint.total;
                pendingBaseline = null;
                pendingBaselineAmbiguous = false;
                interval = null;
                setPhase(turnsClosed ? "complete" : "idle", timestampMs);
                return true;
            }

            case "assistant.idle": {
                if (interval !== null && interval.turnOpen) {
                    interval.ambiguous = true;
                }
                output.updatedAtMs = timestampMs;
                return true;
            }

            case "permission.requested": {
                markAmbiguous(timestampMs);
                return true;
            }

            default:
                output.updatedAtMs = timestampMs;
                return true;
        }
    }

    function heartbeat(nowMs = Date.now()) {
        if (!safeInteger(nowMs)) {
            return false;
        }

        const wasLive = interval !== null ||
            output.recentAtMs !== null ||
            output.phase === "complete";
        let changed = false;
        if (output.recentAtMs !== null &&
            nowMs - output.recentAtMs > RECENT_DELTA_TTL_MS) {
            clearRecent();
            changed = true;
        }
        if (output.phase === "complete" && output.phaseAtMs !== null &&
            nowMs - output.phaseAtMs > COMPLETE_PHASE_TTL_MS) {
            output.phase = "idle";
            output.phaseAtMs = nowMs;
            changed = true;
        }

        if (wasLive || interval !== null || output.recentAtMs !== null ||
            output.phase === "complete") {
            output.updatedAtMs = nowMs;
            changed = true;
        }
        return changed;
    }

    function snapshot() {
        return {
            version: output.version,
            sessionId: output.sessionId,
            updatedAtMs: output.updatedAtMs,
            phase: output.phase,
            phaseAtMs: output.phaseAtMs,
            recentIncreaseNanoAiu: output.recentIncreaseNanoAiu,
            recentAtMs: output.recentAtMs,
        };
    }

    function reset(nowMs = Date.now()) {
        if (!safeInteger(nowMs)) {
            nowMs = Date.now();
        }
        resetBoundary(nowMs);
    }

    return {
        observe,
        heartbeat,
        reset,
        snapshot,
    };
}

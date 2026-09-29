const SESSION_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const EVENT_ID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;
const NANO_AIU_LIMIT = Number.MAX_SAFE_INTEGER;
const RECENT_DELTA_TTL_MS = 120_000;
const COMPLETE_PHASE_TTL_MS = 10_000;
const SUBAGENT_LIFECYCLE_TTL_MS = 300_000;
const MAX_SEEN_EVENT_IDS = 512;
const MAX_PENDING_SUBAGENT_TRANSITIONS = 32;
const MAX_ACTIVE_TOOL_CALLS = 32;
const MAX_AIC_VALIDATION_TURNS = 32;
export const MAX_ACTIVE_SUBAGENTS = 16;
export const RECENT_SUPPRESSION_CODES = Object.freeze([
    "overlap",
    "incomplete",
    "early-usage",
    "no-baseline",
    "no-usage",
    "subagent",
    "reset",
    "interrupted",
    "ambiguous",
]);
const RECENT_SUPPRESSION_MAP = new Map([
    ["overlapping-turns", "overlap"],
    ["overlapping-tools", "overlap"],
    ["incomplete-turns", "incomplete"],
    ["checkpoint-before-turn-end", "early-usage"],
    ["missing-baseline", "no-baseline"],
    ["ambiguous-baseline", "no-baseline"],
    ["missing-final-checkpoint", "no-usage"],
    ["unverified-subagent-attribution", "subagent"],
    ["counter-reset", "reset"],
    ["resume-reset", "reset"],
    ["observer-reset", "reset"],
    ["interruption", "interrupted"],
    ["permission-boundary", "interrupted"],
]);

function recentSuppressionCode(reason) {
    return RECENT_SUPPRESSION_MAP.get(reason) ?? "ambiguous";
}
export const AIC_VALIDATION_REASONS = Object.freeze([
    "baseline-accepted",
    "valid",
    "missing-baseline",
    "ambiguous-baseline",
    "missing-final-checkpoint",
    "counter-reset",
    "interruption",
    "resume-reset",
    "overlapping-turns",
    "overlapping-tools",
    "incomplete-turns",
    "checkpoint-before-turn-end",
    "ambiguous-checkpoint",
    "ambiguous-event-order",
    "ambiguous-event",
    "permission-boundary",
    "tool-correlation",
    "unverified-subagent-attribution",
    "observer-reset",
]);
export const SUBAGENT_COUNT_CHANGE_REASONS = Object.freeze([
    "matched-start",
    "matching-terminal",
    "unmatched-terminal",
    "ambiguous-identity",
    "session-idle-open-agent",
    "lifecycle-lease-expiry",
    "resume-reset",
    "ambiguous-event-order",
    "ambiguous-event",
    "ambiguous-checkpoint",
    "root-turn-boundary",
    "permission-boundary",
    "interruption",
    "tracking-capacity",
    "confirmed-zero-expiry",
    "observer-reset",
]);
export const TOOL_CORRELATION_DIAGNOSTIC_REASONS = Object.freeze([
    "tool-start-missing-event-id",
    "tool-start-interval-absent",
    "tool-start-root-turn-closed",
    "tool-start-missing-call-id",
    "tool-start-active-limit",
    "tool-start-duplicate-call-id",
    "tool-progress-missing-event-id",
    "tool-progress-interval-absent",
    "tool-progress-missing-call-id",
    "tool-progress-unmatched-call-id",
    "tool-complete-missing-event-id",
    "tool-complete-interval-absent",
    "tool-complete-missing-call-id",
    "tool-complete-unmatched-call-id",
]);

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

function newInterval(
    baselineNanoAiu = null,
    unverifiedSubagentActivity = false
) {
    return {
        turnsStarted: 0,
        turnsEnded: 0,
        turnOpen: false,
        lastTurnEndMs: null,
        activeToolCalls: new Set(),
        pendingCheckpoint: null,
        ambiguous: false,
        sawTurn: false,
        baselineNanoAiu,
        baselineBeforeInterval: baselineNanoAiu !== null,
        suppressionReason: unverifiedSubagentActivity
            ? "unverified-subagent-attribution"
            : null,
        overlapObserved: false,
        interruptionObserved: false,
        resetObserved: false,
        counterResetObserved: false,
        unverifiedSubagentActivity,
    };
}

export function createSignalMachine(
    sessionId,
    startedAtMs = Date.now(),
    options = {}
) {
    if (typeof sessionId !== "string" || !SESSION_ID_PATTERN.test(sessionId)) {
        throw new TypeError("A safe CLI session ID is required");
    }
    if (!safeInteger(startedAtMs)) {
        throw new TypeError("The initial timestamp must be a non-negative safe integer");
    }
    if (options === null || typeof options !== "object" ||
        Array.isArray(options)) {
        throw new TypeError("Signal-machine options must be an object");
    }

    const recordSubagentTransitions =
        options.recordSubagentTransitions === true;
    const recordAicValidation = options.recordAicValidation === true;
    const bridgeSessionMatched = options.bridgeSessionMatched === true;
    let baselineTotalNanoAiu = null;
    let pendingBaseline = null;
    let pendingBaselineAmbiguous = false;
    let lastTotalNanoAiu = null;
    let lastTimestampMs = null;
    let interval = null;
    let unverifiedSubagentActivity = false;
    let subagentTrackingUnknown = false;
    const activeSubagents = new Map();
    const pendingSubagentDiagnostics = [];
    let pendingAicValidation = null;
    let confirmedZeroUntilMs = null;
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
        recentSuppressedReason: null,
        activeSubagentCount: null,
    };

    function clearRecent() {
        output.recentIncreaseNanoAiu = null;
        output.recentAtMs = null;
        output.recentSuppressedReason = null;
    }

    function enqueueAicValidation({
        reason,
        validity = "suppressed",
        baselineNanoAiu = null,
        finalCheckpointNanoAiu = null,
        computedDifferenceNanoAiu = null,
        displayedIncreaseNanoAiu = null,
        intervalState = null,
        idleAtMs = null,
        baselineBeforeInterval = false,
        finalCheckpointAccepted = false,
        resetObserved = false,
    }) {
        if (!recordAicValidation) {
            return;
        }

        const turnsStarted = intervalState?.turnsStarted ?? 0;
        const turnsEnded = intervalState?.turnsEnded ?? 0;
        const finalCheckpoint = intervalState?.pendingCheckpoint ?? null;
        const rootTurnsClosed = intervalState !== null &&
            intervalState.sawTurn &&
            turnsStarted > 0 &&
            turnsStarted === turnsEnded &&
            !intervalState.turnOpen;
        const cappedTurnsStarted = Math.min(
            turnsStarted,
            MAX_AIC_VALIDATION_TURNS
        );
        const cappedTurnsEnded = Math.min(
            turnsEnded,
            MAX_AIC_VALIDATION_TURNS
        );
        const eventOrder = {
            bridgeSessionMatched,
            baselineBeforeInterval,
            rootTurnsStarted: cappedTurnsStarted,
            rootTurnsEnded: cappedTurnsEnded,
            rootTurnCountCapped: turnsStarted > MAX_AIC_VALIDATION_TURNS ||
                turnsEnded > MAX_AIC_VALIDATION_TURNS,
            rootTurnsClosed,
            finalCheckpointAccepted,
            finalCheckpointAfterTurnEnd: finalCheckpoint !== null &&
                intervalState?.lastTurnEndMs !== null &&
                finalCheckpoint.timestampMs >= intervalState.lastTurnEndMs,
            idleAfterFinalCheckpoint: finalCheckpoint !== null &&
                idleAtMs !== null &&
                idleAtMs >= finalCheckpoint.timestampMs,
            toolCallsClosed: intervalState === null ||
                intervalState.activeToolCalls.size === 0,
            overlapObserved: intervalState?.overlapObserved === true,
            interruptionObserved:
                intervalState?.interruptionObserved === true,
            resetObserved: resetObserved ||
                intervalState?.resetObserved === true,
            counterResetObserved:
                intervalState?.counterResetObserved === true,
            unverifiedSubagentActivity:
                intervalState?.unverifiedSubagentActivity === true ||
                unverifiedSubagentActivity,
        };

        pendingAicValidation = Object.freeze({
            version: 1,
            validity,
            reason,
            baselineNanoAiu,
            finalCheckpointNanoAiu,
            computedDifferenceNanoAiu,
            displayedIncreaseNanoAiu,
            eventOrder: Object.freeze(eventOrder),
        });
    }

    function setPhase(phase, timestampMs) {
        output.phase = phase;
        output.phaseAtMs = phase === null ? null : timestampMs;
        output.updatedAtMs = timestampMs;
    }

    function enqueueSubagentDiagnostic(diagnostic) {
        if (!recordSubagentTransitions) {
            return;
        }
        if (pendingSubagentDiagnostics.length >= MAX_PENDING_SUBAGENT_TRANSITIONS) {
            pendingSubagentDiagnostics.shift();
        }
        pendingSubagentDiagnostics.push(Object.freeze(diagnostic));
    }

    function setActiveSubagentCount(count, reason, timestampMs) {
        const previousCount = output.activeSubagentCount;
        if (previousCount === count) {
            return;
        }

        output.activeSubagentCount = count;
        enqueueSubagentDiagnostic({
            atMs: timestampMs,
            reason,
            previousCount,
            nextCount: count,
        });
    }

    function markSubagentsUnknown(timestampMs, reason) {
        subagentTrackingUnknown = true;
        activeSubagents.clear();
        confirmedZeroUntilMs = null;
        setActiveSubagentCount(null, reason, timestampMs);
        if (interval !== null) {
            interval.ambiguous = true;
            interval.suppressionReason ??=
                "unverified-subagent-attribution";
            interval.unverifiedSubagentActivity = true;
        }
        baselineTotalNanoAiu = null;
        pendingBaseline = null;
        pendingBaselineAmbiguous = false;
        clearRecent();
        setPhase(output.phase, timestampMs);
    }

    function resetBoundary(timestampMs, phase = null, reason = "resume-reset") {
        const hasAicContext = interval !== null ||
            baselineTotalNanoAiu !== null ||
            pendingBaseline !== null ||
            output.recentAtMs !== null;
        if (hasAicContext) {
            if (reason === "resume-reset" && interval !== null) {
                interval.resetObserved = true;
                interval.suppressionReason ??= "resume-reset";
            }
            enqueueAicValidation({
                reason: reason === "observer-reset"
                    ? "observer-reset"
                    : "resume-reset",
                baselineNanoAiu: interval?.baselineNanoAiu ??
                    baselineTotalNanoAiu,
                intervalState: interval,
                baselineBeforeInterval:
                    interval?.baselineBeforeInterval ??
                    (baselineTotalNanoAiu !== null),
                resetObserved: reason === "resume-reset",
            });
        }
        baselineTotalNanoAiu = null;
        pendingBaseline = null;
        pendingBaselineAmbiguous = false;
        lastTotalNanoAiu = null;
        lastTimestampMs = timestampMs;
        interval = null;
        unverifiedSubagentActivity = false;
        subagentTrackingUnknown = false;
        activeSubagents.clear();
        confirmedZeroUntilMs = null;
        setActiveSubagentCount(null, reason, timestampMs);
        seenEventIds.clear();
        eventIdOrder.length = 0;
        clearRecent();
        setPhase(phase, timestampMs);
    }

    function markAicIntervalAmbiguous(
        timestampMs,
        phase = null,
        reason = "ambiguous-event"
    ) {
        if (interval === null) {
            interval = newInterval(
                baselineTotalNanoAiu,
                unverifiedSubagentActivity
            );
        }
        interval.ambiguous = true;
        interval.suppressionReason ??= reason;
        if (reason === "interruption") {
            interval.interruptionObserved = true;
        } else if (reason === "resume-reset") {
            interval.resetObserved = true;
        } else if (reason === "counter-reset") {
            interval.counterResetObserved = true;
        } else if (reason === "unverified-subagent-attribution") {
            interval.unverifiedSubagentActivity = true;
        } else if (reason === "overlapping-turns" ||
            reason === "overlapping-tools") {
            interval.overlapObserved = true;
        }
        baselineTotalNanoAiu = null;
        pendingBaseline = null;
        pendingBaselineAmbiguous = false;
        clearRecent();
        setPhase(phase, timestampMs);
    }

    function markAmbiguous(
        timestampMs,
        phase = null,
        reason = "ambiguous-event"
    ) {
        if (activeSubagents.size > 0) {
            markSubagentsUnknown(timestampMs, reason);
        }
        const aicReason = reason === "interruption"
            ? "interruption"
            : reason === "ambiguous-event-order"
                ? "ambiguous-event-order"
                : reason === "session-idle-open-agent" ||
                    reason === "ambiguous-identity"
                    ? "unverified-subagent-attribution"
                    : "ambiguous-event";
        markAicIntervalAmbiguous(timestampMs, phase, aicReason);
    }

    function toolDiagnosticContext(event) {
        const agentRef = event.agentRef;
        const caller = agentRef === undefined || agentRef === null
            ? "root"
            : safeId(agentRef) === null
                ? "unknown"
                : "subagent";
        const parentToolCallRef = safeId(event.parentToolCallRef);
        const parentCorrelation = parentToolCallRef === null
            ? "missing"
            : [...activeSubagents.values()].some(
                (agent) => agent.toolCallId === parentToolCallRef
            )
                ? "matched"
                : "unmatched";

        return {
            rootInterval: interval === null
                ? "absent"
                : interval.turnOpen
                    ? "open"
                    : "closed",
            caller,
            parentCorrelation,
        };
    }

    function markAicOnlyToolAmbiguous(timestampMs, phase, reason, event) {
        const context = toolDiagnosticContext(event);
        markAicIntervalAmbiguous(
            timestampMs,
            phase,
            "tool-correlation"
        );
        const count = output.activeSubagentCount;
        enqueueSubagentDiagnostic({
            atMs: timestampMs,
            reason,
            previousCount: count,
            nextCount: count,
            ...context,
        });
    }

    function expireSubagentClaims(timestampMs) {
        let changed = false;
        const hasExpiredAgent = [...activeSubagents.values()].some(
            (agent) => timestampMs - agent.startedAtMs > SUBAGENT_LIFECYCLE_TTL_MS
        );
        if (hasExpiredAgent) {
            markSubagentsUnknown(timestampMs, "lifecycle-lease-expiry");
            changed = true;
        }

        if (output.activeSubagentCount === 0 &&
            confirmedZeroUntilMs !== null &&
            timestampMs > confirmedZeroUntilMs) {
            setActiveSubagentCount(
                null,
                "confirmed-zero-expiry",
                timestampMs
            );
            confirmedZeroUntilMs = null;
            output.updatedAtMs = timestampMs;
            changed = true;
        }
        return changed;
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
            markAmbiguous(
                safeTimestamp(event.timestamp) ?? Date.now(),
                null,
                "interruption"
            );
            return true;
        }
        if (!TRACKED_EVENTS.has(event.type)) {
            return false;
        }

        if (event.type === "session.start") {
            const startTime = safeTimestamp(event.timestamp) ?? Date.now();
            resetBoundary(startTime, "idle", "resume-reset");
            return true;
        }
        if (event.type === "session.resume" ||
            event.type === "session.context_cleared") {
            const resetTime = safeTimestamp(event.timestamp) ?? Date.now();
            resetBoundary(resetTime, null, "resume-reset");
            return true;
        }

        const timestampMs = safeTimestamp(event.timestamp);
        if (timestampMs === null) {
            const invalidTimestampAt = Date.now();
            if (event.type.startsWith("subagent.")) {
                markSubagentsUnknown(
                    invalidTimestampAt,
                    "ambiguous-identity"
                );
                markAicIntervalAmbiguous(
                    invalidTimestampAt,
                    null,
                    "unverified-subagent-attribution"
                );
            } else if (event.type === "session.idle" &&
                activeSubagents.size > 0) {
                markAmbiguous(
                    invalidTimestampAt,
                    null,
                    "session-idle-open-agent"
                );
            } else {
                markAicIntervalAmbiguous(
                    invalidTimestampAt,
                    null,
                    "ambiguous-event"
                );
            }
            return true;
        }
        if (lastTimestampMs !== null && timestampMs < lastTimestampMs) {
            const reason = event.type.startsWith("subagent.")
                ? "ambiguous-identity"
                : "ambiguous-event-order";
            markAmbiguous(timestampMs, null, reason);
            if (event.type.startsWith("subagent.")) {
                markSubagentsUnknown(timestampMs, reason);
            }
            lastTimestampMs = Math.max(lastTimestampMs, timestampMs);
            return true;
        }
        lastTimestampMs = timestampMs;

        const eventId = safeId(event.id);
        if (eventId !== null && rememberEventId(eventId)) {
            return false;
        }
        expireSubagentClaims(timestampMs);
        const criticalEvent = event.type === "assistant.turn_start" ||
            event.type === "assistant.turn_end" ||
            event.type === "session.idle" ||
            event.type === "session.usage_checkpoint" ||
            event.type === "subagent.started" ||
            event.type === "subagent.completed" ||
            event.type === "subagent.failed" ||
            event.type === "tool.execution_start" ||
            event.type === "tool.execution_complete" ||
            event.type === "tool.execution_progress";
        if (criticalEvent && eventId === null) {
            if (event.type.startsWith("tool.")) {
                const action = event.type.slice("tool.execution_".length);
                const reason = `tool-${action}-missing-event-id`;
                markAicOnlyToolAmbiguous(
                    timestampMs,
                    action === "start" ? "running_tool" : null,
                    reason,
                    event
                );
                return true;
            } else if (event.type.startsWith("subagent.")) {
                markAmbiguous(
                    timestampMs,
                    null,
                    "ambiguous-identity"
                );
            } else if (event.type === "session.idle" &&
                activeSubagents.size > 0) {
                markAmbiguous(
                    timestampMs,
                    null,
                    "session-idle-open-agent"
                );
            } else {
                markAicIntervalAmbiguous(
                    timestampMs,
                    null,
                    "ambiguous-event"
                );
            }
        }

        const data = event.data && typeof event.data === "object" &&
            !Array.isArray(event.data)
            ? event.data
            : {};

        if (event.type.startsWith("subagent.")) {
            unverifiedSubagentActivity = true;
            if (interval !== null) {
                interval.ambiguous = true;
                interval.suppressionReason ??=
                    "unverified-subagent-attribution";
                interval.unverifiedSubagentActivity = true;
            }
            baselineTotalNanoAiu = null;
            pendingBaseline = null;
            clearRecent();

            if (subagentTrackingUnknown) {
                setPhase(output.phase, timestampMs);
                return true;
            }

            const agentId = safeId(event.agentId);
            const toolCallId = safeId(data.toolCallId);
            if (eventId === null || agentId === null || toolCallId === null) {
                markSubagentsUnknown(timestampMs, "ambiguous-identity");
                return true;
            }

            if (event.type === "subagent.started") {
                if (activeSubagents.has(agentId)) {
                    markSubagentsUnknown(timestampMs, "ambiguous-identity");
                    return true;
                }
                if (activeSubagents.size >= MAX_ACTIVE_SUBAGENTS) {
                    markSubagentsUnknown(timestampMs, "tracking-capacity");
                    return true;
                }
                confirmedZeroUntilMs = null;
                activeSubagents.set(agentId, { toolCallId, startedAtMs: timestampMs });
                setActiveSubagentCount(
                    activeSubagents.size,
                    "matched-start",
                    timestampMs
                );
                setPhase(output.phase, timestampMs);
                return true;
            }

            const activeAgent = activeSubagents.get(agentId);
            if (activeAgent === undefined) {
                markSubagentsUnknown(timestampMs, "unmatched-terminal");
                return true;
            }
            if (activeAgent.toolCallId !== toolCallId) {
                markSubagentsUnknown(timestampMs, "ambiguous-identity");
                return true;
            }
            activeSubagents.delete(agentId);
            setActiveSubagentCount(
                activeSubagents.size,
                "matching-terminal",
                timestampMs
            );
            confirmedZeroUntilMs = activeSubagents.size === 0
                ? timestampMs + SUBAGENT_LIFECYCLE_TTL_MS
                : null;
            setPhase(output.phase, timestampMs);
            return true;
        }

        switch (event.type) {
            case "assistant.turn_start": {
                if (pendingBaseline !== null) {
                    pendingBaseline = null;
                    pendingBaselineAmbiguous = false;
                    baselineTotalNanoAiu = null;
                    interval = newInterval(
                        null,
                        unverifiedSubagentActivity
                    );
                    interval.ambiguous = true;
                    interval.suppressionReason ??= "ambiguous-baseline";
                } else if (interval === null) {
                    interval = newInterval(
                        baselineTotalNanoAiu,
                        unverifiedSubagentActivity
                    );
                    clearRecent();
                } else if (interval.pendingCheckpoint !== null) {
                    interval.ambiguous = true;
                    interval.suppressionReason ??= "ambiguous-checkpoint";
                    interval.pendingCheckpoint = null;
                }

                if (interval.turnOpen) {
                    interval.ambiguous = true;
                    interval.overlapObserved = true;
                    interval.suppressionReason ??= "overlapping-turns";
                }
                interval.turnOpen = true;
                interval.turnsStarted += 1;
                interval.sawTurn = true;
                setPhase("working", timestampMs);
                return true;
            }

            case "assistant.turn_end": {
                if (interval === null || !interval.turnOpen) {
                    markAicIntervalAmbiguous(
                        timestampMs,
                        null,
                        "incomplete-turns"
                    );
                    return true;
                }
                if (interval.activeToolCalls.size > 0) {
                    interval.ambiguous = true;
                    interval.overlapObserved = true;
                    interval.suppressionReason ??= "overlapping-tools";
                }
                interval.turnOpen = false;
                interval.turnsEnded += 1;
                interval.lastTurnEndMs = timestampMs;
                setPhase("working", timestampMs);
                return true;
            }

            case "tool.execution_start": {
                const toolCallId = safeId(data.toolCallId);
                const failureReason = interval === null
                    ? "tool-start-interval-absent"
                    : !interval.turnOpen
                        ? "tool-start-root-turn-closed"
                        : toolCallId === null
                            ? "tool-start-missing-call-id"
                            : interval.activeToolCalls.size >= MAX_ACTIVE_TOOL_CALLS
                                ? "tool-start-active-limit"
                                : interval.activeToolCalls.has(toolCallId)
                                    ? "tool-start-duplicate-call-id"
                                    : null;
                if (failureReason !== null) {
                    markAicOnlyToolAmbiguous(
                        timestampMs,
                        "running_tool",
                        failureReason,
                        event
                    );
                    return true;
                }
                if (interval.activeToolCalls.size > 0) {
                    interval.ambiguous = true;
                    interval.overlapObserved = true;
                    interval.suppressionReason ??= "overlapping-tools";
                }
                interval.activeToolCalls.add(toolCallId);
                setPhase("running_tool", timestampMs);
                return true;
            }

            case "tool.execution_progress": {
                const toolCallId = safeId(data.toolCallId);
                const failureReason = interval === null
                    ? "tool-progress-interval-absent"
                    : toolCallId === null
                        ? "tool-progress-missing-call-id"
                        : !interval.activeToolCalls.has(toolCallId)
                            ? "tool-progress-unmatched-call-id"
                            : null;
                if (failureReason !== null) {
                    markAicOnlyToolAmbiguous(
                        timestampMs,
                        null,
                        failureReason,
                        event
                    );
                    return true;
                }
                setPhase("running_tool", timestampMs);
                return true;
            }

            case "tool.execution_complete": {
                const toolCallId = safeId(data.toolCallId);
                const failureReason = interval === null
                    ? "tool-complete-interval-absent"
                    : toolCallId === null
                        ? "tool-complete-missing-call-id"
                        : !interval.activeToolCalls.has(toolCallId)
                            ? "tool-complete-unmatched-call-id"
                            : null;
                if (failureReason !== null) {
                    markAicOnlyToolAmbiguous(
                        timestampMs,
                        null,
                        failureReason,
                        event
                    );
                    return true;
                }
                interval.activeToolCalls.delete(toolCallId);
                setPhase("working", timestampMs);
                return true;
            }

            case "session.usage_checkpoint": {
                const total = data.totalNanoAiu;
                if (!safeInteger(total)) {
                    markAicIntervalAmbiguous(
                        timestampMs,
                        null,
                        "ambiguous-checkpoint"
                    );
                    lastTotalNanoAiu = null;
                    return true;
                }
                if (lastTotalNanoAiu !== null && total < lastTotalNanoAiu) {
                    baselineTotalNanoAiu = null;
                    pendingBaseline = null;
                    clearRecent();
                    if (interval !== null) {
                        interval.ambiguous = true;
                        interval.counterResetObserved = true;
                        interval.suppressionReason ??= "counter-reset";
                    } else {
                        const resetDiagnosticInterval = newInterval(
                            baselineTotalNanoAiu,
                            unverifiedSubagentActivity
                        );
                        resetDiagnosticInterval.counterResetObserved = true;
                        resetDiagnosticInterval.pendingCheckpoint = {
                            total,
                            timestampMs,
                        };
                        enqueueAicValidation({
                            reason: "counter-reset",
                            baselineNanoAiu: baselineTotalNanoAiu,
                            finalCheckpointNanoAiu: total,
                            computedDifferenceNanoAiu:
                                baselineTotalNanoAiu === null
                                    ? null
                                    : total - baselineTotalNanoAiu,
                            intervalState: resetDiagnosticInterval,
                            baselineBeforeInterval:
                                baselineTotalNanoAiu !== null,
                        });
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
                    interval.suppressionReason ??= "ambiguous-checkpoint";
                }
                if (!interval.sawTurn || interval.turnOpen ||
                    interval.turnsStarted !== interval.turnsEnded ||
                    interval.activeToolCalls.size > 0) {
                    interval.ambiguous = true;
                    interval.suppressionReason ??=
                        interval.activeToolCalls.size > 0
                            ? "overlapping-tools"
                            : "checkpoint-before-turn-end";
                }
                interval.pendingCheckpoint = checkpoint;
                output.updatedAtMs = timestampMs;
                return true;
            }

            case "session.idle": {
                if (activeSubagents.size > 0) {
                    markSubagentsUnknown(
                        timestampMs,
                        "session-idle-open-agent"
                    );
                }
                if (interval === null) {
                    if (pendingBaseline !== null && !pendingBaselineAmbiguous) {
                        baselineTotalNanoAiu = pendingBaseline.total;
                        enqueueAicValidation({
                            reason: "baseline-accepted",
                            validity: "pending",
                            baselineNanoAiu: baselineTotalNanoAiu,
                            baselineBeforeInterval: true,
                        });
                    } else if (pendingBaselineAmbiguous) {
                        baselineTotalNanoAiu = null;
                        enqueueAicValidation({
                            reason: "ambiguous-baseline",
                        });
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

                const validIncrease = validInterval &&
                    baselineTotalNanoAiu !== null &&
                    finalCheckpoint.total >= baselineTotalNanoAiu;
                const computedDifferenceNanoAiu =
                    finalCheckpoint !== null &&
                    interval.baselineNanoAiu !== null
                        ? finalCheckpoint.total - interval.baselineNanoAiu
                        : null;
                if (validIncrease) {
                    output.recentIncreaseNanoAiu =
                        finalCheckpoint.total - baselineTotalNanoAiu;
                    output.recentAtMs = timestampMs;
                } else {
                    clearRecent();
                }

                let validationReason = interval.suppressionReason;
                if (validIncrease) {
                    validationReason = "valid";
                } else if (validationReason === null) {
                    validationReason = baselineTotalNanoAiu === null
                        ? "missing-baseline"
                        : finalCheckpoint === null
                            ? "missing-final-checkpoint"
                            : !turnsClosed
                                ? "incomplete-turns"
                                : !toolsClosed
                                    ? "overlapping-tools"
                                    : !checkpointFollowsTurn
                                        ? "checkpoint-before-turn-end"
                                        : unverifiedSubagentActivity
                                            ? "unverified-subagent-attribution"
                                            : finalCheckpoint.total <
                                                baselineTotalNanoAiu
                                                ? "counter-reset"
                                                : "ambiguous-event";
                }
                if (!validIncrease) {
                    output.recentSuppressedReason =
                        recentSuppressionCode(validationReason);
                    output.recentAtMs = timestampMs;
                }
                enqueueAicValidation({
                    reason: validationReason,
                    validity: validIncrease ? "valid" : "suppressed",
                    baselineNanoAiu: interval.baselineNanoAiu,
                    finalCheckpointNanoAiu: finalCheckpoint?.total ?? null,
                    computedDifferenceNanoAiu,
                    displayedIncreaseNanoAiu:
                        output.recentIncreaseNanoAiu,
                    intervalState: interval,
                    idleAtMs: timestampMs,
                    baselineBeforeInterval:
                        interval.baselineBeforeInterval,
                    finalCheckpointAccepted: validIncrease,
                });

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
                    interval.suppressionReason ??= "incomplete-turns";
                }
                output.updatedAtMs = timestampMs;
                return true;
            }

            case "permission.requested": {
                markAicIntervalAmbiguous(
                    timestampMs,
                    null,
                    "permission-boundary"
                );
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

        let changed = expireSubagentClaims(nowMs);
        const wasLive = interval !== null ||
            output.recentAtMs !== null ||
            output.phase === "complete" ||
            output.activeSubagentCount > 0 ||
            (output.activeSubagentCount === 0 &&
                confirmedZeroUntilMs !== null &&
                nowMs <= confirmedZeroUntilMs);
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
            output.phase === "complete" ||
            output.activeSubagentCount > 0) {
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
            recentSuppressedReason: output.recentSuppressedReason,
            activeSubagentCount: output.activeSubagentCount,
        };
    }

    function drainSubagentDiagnostics() {
        return pendingSubagentDiagnostics.splice(
            0,
            pendingSubagentDiagnostics.length
        );
    }

    function drainAicValidation() {
        const diagnostic = pendingAicValidation;
        pendingAicValidation = null;
        return diagnostic;
    }

    function reset(nowMs = Date.now(), reason = "observer-reset") {
        if (!safeInteger(nowMs)) {
            nowMs = Date.now();
        }
        resetBoundary(nowMs, null, reason);
    }

    return {
        observe,
        heartbeat,
        drainSubagentDiagnostics,
        drainAicValidation,
        reset,
        snapshot,
    };
}

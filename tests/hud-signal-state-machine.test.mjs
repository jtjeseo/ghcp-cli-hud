import assert from "node:assert/strict";
import test from "node:test";
import { createSignalMachine } from "../.github/extensions/hud-signal-bridge/state-machine.mjs";

let nextId = 0;

function event(type, milliseconds, data = {}, overrides = {}) {
    nextId += 1;
    return {
        id: `fixture-event-${nextId}`,
        type,
        timestamp: new Date(milliseconds).toISOString(),
        data,
        ...overrides,
    };
}

function observe(machine, type, milliseconds, data = {}, overrides = {}) {
    machine.observe(event(type, milliseconds, data, overrides));
}

function setBaseline(machine, total, milliseconds) {
    observe(machine, "session.usage_checkpoint", milliseconds, {
        totalNanoAiu: total,
    });
    observe(machine, "assistant.idle", milliseconds + 1);
    observe(machine, "session.idle", milliseconds + 2);
}

function completeTurn(machine, total, start, turnId = 0) {
    observe(machine, "assistant.turn_start", start, { turnId });
    observe(machine, "assistant.turn_end", start + 5, { turnId });
    observe(machine, "session.usage_checkpoint", start + 10, {
        totalNanoAiu: total,
    });
    observe(machine, "assistant.idle", start + 11);
    observe(machine, "session.idle", start + 12);
}

function createDiagnosticMachine(sessionId, startedAtMs) {
    return createSignalMachine(sessionId, startedAtMs, {
        recordSubagentTransitions: true,
    });
}

function createAicValidationMachine(sessionId, startedAtMs) {
    return createSignalMachine(sessionId, startedAtMs, {
        recordAicValidation: true,
        bridgeSessionMatched: true,
    });
}

function startSubagent(
    machine,
    milliseconds,
    agentId = "agent-1",
    toolCallId = "spawn-call-1"
) {
    observe(
        machine,
        "subagent.started",
        milliseconds,
        { toolCallId },
        { agentId }
    );
}

test("groups sequential internal turns by busy interval, not turnId", () => {
    const machine = createSignalMachine("session-a", 1_000);
    setBaseline(machine, 100, 1_010);

    observe(machine, "assistant.turn_start", 1_020, {
        turnId: 0,
        prompt: "must not be persisted",
    });
    observe(machine, "assistant.usage", 1_021, {
        copilotUsage: { totalNanoAiu: 90_000 },
    });
    observe(machine, "tool.execution_start", 1_022, {
        toolCallId: "fixture-call-1",
        toolName: "must not be persisted",
    });
    observe(machine, "tool.execution_complete", 1_023, {
        toolCallId: "fixture-call-1",
        result: "must not be persisted",
    });
    observe(machine, "assistant.turn_end", 1_024, { turnId: 0 });
    observe(machine, "assistant.turn_start", 1_025, { turnId: 0 });
    observe(machine, "assistant.usage", 1_026, {
        copilotUsage: { totalNanoAiu: 80_000 },
    });
    observe(machine, "assistant.turn_end", 1_027, { turnId: 0 });
    observe(machine, "session.usage_checkpoint", 1_028, {
        totalNanoAiu: 135,
    });
    observe(machine, "assistant.idle", 1_029);
    observe(machine, "session.idle", 1_030);

    const snapshot = machine.snapshot();
    assert.equal(snapshot.recentIncreaseNanoAiu, 35);
    assert.equal(snapshot.phase, "complete");
    assert.deepEqual(Object.keys(snapshot).sort(), [
        "activeSubagentCount",
        "phase",
        "phaseAtMs",
        "recentAtMs",
        "recentIncreaseNanoAiu",
        "sessionId",
        "updatedAtMs",
        "version",
    ]);
    assert.equal(JSON.stringify(snapshot).includes("must not be persisted"), false);
});

test("supports two sequential busy intervals and advances the baseline", () => {
    const machine = createSignalMachine("session-b", 2_000);
    setBaseline(machine, 500, 2_010);

    completeTurn(machine, 512, 2_020, 0);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 12);

    completeTurn(machine, 530, 2_040, 0);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 18);
});

test("replays the sanitized 1606 checkpoint and two-turn shape as a fixture", () => {
    const machine = createSignalMachine("observed-shape", 1_758_824_000_000);
    const time = (value) => Date.parse(value);

    observe(machine, "session.usage_checkpoint", time("2026-09-25T20:11:48.754Z"), {
        totalNanoAiu: 199_355_000,
    });
    observe(machine, "assistant.idle", time("2026-09-25T20:11:48.754Z"));
    observe(machine, "session.idle", time("2026-09-25T20:11:48.757Z"));
    observe(machine, "assistant.turn_start", time("2026-09-25T20:12:00.508Z"), {
        turnId: 0,
    });
    observe(machine, "assistant.usage", time("2026-09-25T20:12:03.122Z"), {
        copilotUsage: { totalNanoAiu: 21_231_000 },
    });
    observe(machine, "tool.execution_start", time("2026-09-25T20:12:03.144Z"), {
        toolCallId: "fixture-call-matched",
    });
    observe(machine, "tool.execution_complete", time("2026-09-25T20:12:03.146Z"), {
        toolCallId: "fixture-call-matched",
    });
    observe(machine, "assistant.turn_end", time("2026-09-25T20:12:03.151Z"), {
        turnId: 0,
    });
    observe(machine, "assistant.turn_start", time("2026-09-25T20:12:03.151Z"), {
        turnId: 1,
    });
    observe(machine, "assistant.usage", time("2026-09-25T20:12:04.263Z"), {
        copilotUsage: { totalNanoAiu: 18_676_500 },
    });
    observe(machine, "assistant.turn_end", time("2026-09-25T20:12:04.278Z"), {
        turnId: 1,
    });
    observe(machine, "session.usage_checkpoint", time("2026-09-25T20:12:04.280Z"), {
        totalNanoAiu: 239_262_500,
    });
    observe(machine, "assistant.idle", time("2026-09-25T20:12:04.280Z"));
    observe(machine, "session.idle", time("2026-09-25T20:12:04.284Z"));

    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 39_907_500);
    assert.equal(21_231_000 + 18_676_500, 39_907_500);
    assert.equal(machine.snapshot().phase, "complete");
});

test("uses checkpoint difference only, not per-call usage", () => {
    const machine = createSignalMachine("session-c", 3_000);
    setBaseline(machine, 1_000, 3_010);

    observe(machine, "assistant.turn_start", 3_020, { turnId: 0 });
    observe(machine, "assistant.usage", 3_021, {
        copilotUsage: { totalNanoAiu: 9_999 },
    });
    observe(machine, "assistant.turn_end", 3_022, { turnId: 0 });
    observe(machine, "session.usage_checkpoint", 3_023, {
        totalNanoAiu: 1_007,
    });
    observe(machine, "session.idle", 3_024);

    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 7);
});

test("validates the accepted checkpoint pair and displayed difference", () => {
    const machine = createAicValidationMachine("aic-validation-valid", 3_100);
    setBaseline(machine, 100, 3_110);
    const baselineRecord = machine.drainAicValidation();
    assert.equal(baselineRecord.validity, "pending");
    assert.equal(baselineRecord.reason, "baseline-accepted");
    assert.equal(baselineRecord.baselineNanoAiu, 100);

    completeTurn(machine, 135, 3_120);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 35);
    assert.deepEqual(machine.drainAicValidation(), {
        version: 1,
        validity: "valid",
        reason: "valid",
        baselineNanoAiu: 100,
        finalCheckpointNanoAiu: 135,
        computedDifferenceNanoAiu: 35,
        displayedIncreaseNanoAiu: 35,
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
    });
});

test("records multiple sequential internal turns in one valid interval", () => {
    const machine = createAicValidationMachine("aic-validation-multi-turn", 3_300);
    setBaseline(machine, 500, 3_310);

    observe(machine, "assistant.turn_start", 3_320, { turnId: 0 });
    observe(machine, "assistant.turn_end", 3_325, { turnId: 0 });
    observe(machine, "assistant.turn_start", 3_326, { turnId: 1 });
    observe(machine, "assistant.turn_end", 3_331, { turnId: 1 });
    observe(machine, "session.usage_checkpoint", 3_332, {
        totalNanoAiu: 545,
    });
    observe(machine, "session.idle", 3_333);

    const validation = machine.drainAicValidation();
    assert.equal(validation.validity, "valid");
    assert.equal(validation.computedDifferenceNanoAiu, 45);
    assert.equal(validation.eventOrder.rootTurnsStarted, 2);
    assert.equal(validation.eventOrder.rootTurnsEnded, 2);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 45);
});

test("suppresses AIC validation when the accepted baseline is missing", () => {
    const machine = createAicValidationMachine("aic-validation-no-baseline", 3_400);
    completeTurn(machine, 135, 3_410);

    const validation = machine.drainAicValidation();
    assert.equal(validation.validity, "suppressed");
    assert.equal(validation.reason, "missing-baseline");
    assert.equal(validation.baselineNanoAiu, null);
    assert.equal(validation.finalCheckpointNanoAiu, 135);
    assert.equal(validation.computedDifferenceNanoAiu, null);
    assert.equal(validation.displayedIncreaseNanoAiu, null);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);
});

test("records counter resets as negative candidates without displaying them", () => {
    const machine = createAicValidationMachine("aic-validation-reset", 3_500);
    setBaseline(machine, 900, 3_510);
    completeTurn(machine, 40, 3_520);

    const validation = machine.drainAicValidation();
    assert.equal(validation.validity, "suppressed");
    assert.equal(validation.reason, "counter-reset");
    assert.equal(validation.baselineNanoAiu, 900);
    assert.equal(validation.finalCheckpointNanoAiu, 40);
    assert.equal(validation.computedDifferenceNanoAiu, -860);
    assert.equal(validation.displayedIncreaseNanoAiu, null);
    assert.equal(validation.eventOrder.counterResetObserved, true);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);
});

test("records interruption and resume suppression without a displayed delta", () => {
    const interrupted = createAicValidationMachine(
        "aic-validation-interruption",
        3_600
    );
    setBaseline(interrupted, 100, 3_610);
    observe(interrupted, "assistant.turn_start", 3_620, { turnId: 0 });
    observe(interrupted, "assistant.turn_interrupted", 3_621);
    observe(interrupted, "assistant.turn_end", 3_622, { turnId: 0 });
    observe(interrupted, "session.usage_checkpoint", 3_623, {
        totalNanoAiu: 120,
    });
    observe(interrupted, "session.idle", 3_624);
    const interruptedValidation = interrupted.drainAicValidation();
    assert.equal(interruptedValidation.reason, "interruption");
    assert.equal(interruptedValidation.validity, "suppressed");
    assert.equal(interruptedValidation.displayedIncreaseNanoAiu, null);
    assert.equal(
        interruptedValidation.eventOrder.interruptionObserved,
        true
    );
    assert.equal(interrupted.snapshot().recentIncreaseNanoAiu, null);

    const resumed = createAicValidationMachine("aic-validation-resume", 3_700);
    setBaseline(resumed, 100, 3_710);
    observe(resumed, "assistant.turn_start", 3_720, { turnId: 0 });
    observe(resumed, "session.resume", 3_721);
    const resumeValidation = resumed.drainAicValidation();
    assert.equal(resumeValidation.reason, "resume-reset");
    assert.equal(resumeValidation.validity, "suppressed");
    assert.equal(resumeValidation.displayedIncreaseNanoAiu, null);
    assert.equal(resumeValidation.eventOrder.resetObserved, true);
    assert.equal(resumed.snapshot().recentIncreaseNanoAiu, null);
});

test("records overlapping turns and unverified subagent attribution as suppression", () => {
    const overlapping = createAicValidationMachine(
        "aic-validation-overlap",
        3_800
    );
    setBaseline(overlapping, 100, 3_810);
    observe(overlapping, "assistant.turn_start", 3_820, { turnId: 0 });
    observe(overlapping, "assistant.turn_start", 3_821, { turnId: 1 });
    observe(overlapping, "assistant.turn_end", 3_822, { turnId: 0 });
    observe(overlapping, "assistant.turn_end", 3_823, { turnId: 1 });
    observe(overlapping, "session.usage_checkpoint", 3_824, {
        totalNanoAiu: 140,
    });
    observe(overlapping, "session.idle", 3_825);
    const overlapValidation = overlapping.drainAicValidation();
    assert.equal(overlapValidation.reason, "overlapping-turns");
    assert.equal(overlapValidation.eventOrder.overlapObserved, true);
    assert.equal(overlapValidation.displayedIncreaseNanoAiu, null);
    assert.equal(overlapping.snapshot().recentIncreaseNanoAiu, null);

    const subagent = createAicValidationMachine(
        "aic-validation-subagent",
        3_900
    );
    setBaseline(subagent, 100, 3_910);
    observe(subagent, "assistant.turn_start", 3_920, { turnId: 0 });
    startSubagent(subagent, 3_921, "unverified-agent", "spawn-call");
    observe(subagent, "assistant.turn_end", 3_922, { turnId: 0 });
    observe(subagent, "session.usage_checkpoint", 3_923, {
        totalNanoAiu: 120,
    });
    observe(subagent, "session.idle", 3_924);
    const subagentValidation = subagent.drainAicValidation();
    assert.equal(
        subagentValidation.reason,
        "unverified-subagent-attribution"
    );
    assert.equal(
        subagentValidation.eventOrder.unverifiedSubagentActivity,
        true
    );
    assert.equal(subagentValidation.displayedIncreaseNanoAiu, null);
    assert.equal(subagent.snapshot().recentIncreaseNanoAiu, null);
});

test("keeps checkpoint arithmetic exact for the displayed AIU precision", () => {
    const machine = createAicValidationMachine("aic-validation-rounding", 4_000);
    setBaseline(machine, 1_000_000_000, 4_010);
    completeTurn(machine, 7_390_000_000, 4_020);

    const validation = machine.drainAicValidation();
    assert.equal(validation.validity, "valid");
    assert.equal(validation.computedDifferenceNanoAiu, 6_390_000_000);
    assert.equal(validation.displayedIncreaseNanoAiu, 6_390_000_000);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 6_390_000_000);
});

test("AIC validation leaves the normal derived-state snapshot unchanged", () => {
    const regular = createSignalMachine("aic-validation-schema", 4_100);
    const diagnostic = createAicValidationMachine("aic-validation-schema", 4_100);
    setBaseline(regular, 100, 4_110);
    setBaseline(diagnostic, 100, 4_110);
    completeTurn(regular, 135, 4_120);
    completeTurn(diagnostic, 135, 4_120);

    assert.deepEqual(diagnostic.snapshot(), regular.snapshot());
    assert.deepEqual(Object.keys(diagnostic.snapshot()).sort(), [
        "activeSubagentCount",
        "phase",
        "phaseAtMs",
        "recentAtMs",
        "recentIncreaseNanoAiu",
        "sessionId",
        "updatedAtMs",
        "version",
    ]);
});

test("suppresses a busy interval with no final checkpoint and requires a new baseline", () => {
    const machine = createSignalMachine("session-d", 4_000);
    setBaseline(machine, 2_000, 4_010);

    observe(machine, "assistant.turn_start", 4_020, { turnId: 0 });
    observe(machine, "assistant.turn_end", 4_021, { turnId: 0 });
    observe(machine, "session.idle", 4_022);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);

    setBaseline(machine, 2_100, 4_030);
    completeTurn(machine, 2_105, 4_040);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 5);
});

test("suppresses and rebases after a cumulative counter reset", () => {
    const machine = createSignalMachine("session-e", 5_000);
    setBaseline(machine, 900, 5_010);

    completeTurn(machine, 40, 5_020);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);

    completeTurn(machine, 48, 5_040);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 8);
});

test("suppresses overlapping turns", () => {
    const machine = createSignalMachine("session-f", 6_000);
    setBaseline(machine, 100, 6_010);

    observe(machine, "assistant.turn_start", 6_020, { turnId: 0 });
    observe(machine, "assistant.turn_start", 6_021, { turnId: 1 });
    observe(machine, "assistant.turn_end", 6_022, { turnId: 0 });
    observe(machine, "assistant.turn_end", 6_023, { turnId: 1 });
    observe(machine, "session.usage_checkpoint", 6_024, {
        totalNanoAiu: 140,
    });
    observe(machine, "session.idle", 6_025);

    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);
});

test("suppresses interrupted, unmatched, and out-of-order boundaries", () => {
    const interrupted = createSignalMachine("session-g", 7_000);
    setBaseline(interrupted, 100, 7_010);
    observe(interrupted, "assistant.turn_start", 7_020, { turnId: 0 });
    observe(interrupted, "session.idle", 7_021);
    assert.equal(interrupted.snapshot().recentIncreaseNanoAiu, null);

    const outOfOrder = createSignalMachine("session-h", 8_000);
    setBaseline(outOfOrder, 100, 8_010);
    observe(outOfOrder, "assistant.turn_start", 8_020, { turnId: 0 });
    observe(outOfOrder, "assistant.turn_end", 8_019, { turnId: 0 });
    observe(outOfOrder, "session.usage_checkpoint", 8_021, {
        totalNanoAiu: 140,
    });
    observe(outOfOrder, "session.idle", 8_022);
    assert.equal(outOfOrder.snapshot().recentIncreaseNanoAiu, null);

    const cancelled = createSignalMachine("session-h2", 8_100);
    setBaseline(cancelled, 100, 8_110);
    observe(cancelled, "assistant.turn_start", 8_120, { turnId: 0 });
    observe(cancelled, "assistant.turn_interrupted", 8_121);
    observe(cancelled, "assistant.turn_end", 8_122, { turnId: 0 });
    observe(cancelled, "session.usage_checkpoint", 8_123, {
        totalNanoAiu: 140,
    });
    observe(cancelled, "session.idle", 8_124);
    assert.equal(cancelled.snapshot().recentIncreaseNanoAiu, null);
});

test("resets its baseline on resume", () => {
    const machine = createSignalMachine("session-i", 9_000);
    setBaseline(machine, 100, 9_010);

    observe(machine, "session.resume", 9_020);
    completeTurn(machine, 200, 9_030);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);

    completeTurn(machine, 209, 9_050);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 9);
});

test("resets its baseline when session context is cleared", () => {
    const machine = createSignalMachine("session-i2", 9_500);
    setBaseline(machine, 100, 9_510);

    observe(machine, "session.context_cleared", 9_520);
    completeTurn(machine, 200, 9_530);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);

    completeTurn(machine, 206, 9_550);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 6);
});

test("keeps sessions isolated", () => {
    const first = createSignalMachine("session-j", 10_000);
    const second = createSignalMachine("session-k", 10_000);
    setBaseline(first, 100, 10_010);
    setBaseline(second, 1_000, 10_010);

    completeTurn(first, 110, 10_020);
    assert.equal(first.snapshot().recentIncreaseNanoAiu, 10);
    assert.equal(second.snapshot().recentIncreaseNanoAiu, null);
    assert.equal(second.snapshot().sessionId, "session-k");
});

test("suppresses the interval after unverified subagent activity", () => {
    const machine = createSignalMachine("session-l", 11_000);
    setBaseline(machine, 100, 11_010);

    observe(machine, "assistant.turn_start", 11_020, { turnId: 0 });
    observe(
        machine,
        "subagent.started",
        11_021,
        { toolCallId: "fixture-parent-call" },
        { agentId: "child-1" }
    );
    observe(machine, "assistant.turn_end", 11_022, { turnId: 0 });
    observe(machine, "session.usage_checkpoint", 11_023, {
        totalNanoAiu: 140,
    });
    observe(machine, "session.idle", 11_024);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);
    assert.equal(machine.snapshot().activeSubagentCount, null);

    completeTurn(machine, 150, 11_030);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);
});

test("tracks overlapping subagents by matched agent and spawning-call IDs", () => {
    const machine = createSignalMachine("fleet-overlap", 15_000);
    observe(machine, "assistant.turn_start", 15_020, { turnId: 0 }, {
        agentId: "agent-1",
    });
    assert.equal(machine.snapshot().activeSubagentCount, null);

    observe(machine, "tool.execution_start", 15_021, {
        toolCallId: "spawn-call-3",
    });
    observe(machine, "tool.execution_start", 15_022, {
        toolCallId: "spawn-call-2",
    });
    observe(
        machine,
        "subagent.started",
        15_023,
        { toolCallId: "spawn-call-3" },
        { agentId: "agent-1" }
    );
    observe(
        machine,
        "subagent.started",
        15_024,
        { toolCallId: "spawn-call-2" },
        { agentId: "agent-2" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 2);

    observe(
        machine,
        "tool.execution_start",
        15_025,
        { toolCallId: "child-call-4", parentToolCallId: "spawn-call-3" },
        { agentId: "agent-1" }
    );
    observe(
        machine,
        "tool.execution_start",
        15_026,
        { toolCallId: "child-call-5", parentToolCallId: "spawn-call-2" },
        { agentId: "agent-2" }
    );
    observe(
        machine,
        "tool.execution_complete",
        15_027,
        { toolCallId: "child-call-4", parentToolCallId: "spawn-call-3" },
        { agentId: "agent-1" }
    );
    observe(
        machine,
        "tool.execution_complete",
        15_028,
        { toolCallId: "child-call-5", parentToolCallId: "spawn-call-2" },
        { agentId: "agent-2" }
    );

    observe(machine, "tool.execution_complete", 15_029, {
        toolCallId: "spawn-call-3",
    });
    observe(machine, "tool.execution_complete", 15_030, {
        toolCallId: "spawn-call-2",
    });
    assert.equal(machine.snapshot().activeSubagentCount, 2);

    observe(
        machine,
        "subagent.completed",
        15_031,
        { toolCallId: "spawn-call-2" },
        { agentId: "agent-2" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 1);
    observe(
        machine,
        "subagent.completed",
        15_032,
        { toolCallId: "spawn-call-3" },
        { agentId: "agent-1" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 0);
    observe(machine, "session.idle", 15_033);

    const serialized = JSON.stringify(machine.snapshot());
    assert.equal(serialized.includes("agent-1"), false);
    assert.equal(serialized.includes("spawn-call-3"), false);
    assert.equal(serialized.includes("child-call-4"), false);
});

test("accepts child tools after their parallel parent calls have completed", () => {
    const startedAt = 15_100;
    const machine = createDiagnosticMachine("fleet-parent-first", startedAt);
    observe(machine, "assistant.turn_start", startedAt + 1, { turnId: 0 });
    observe(machine, "tool.execution_start", startedAt + 2, {
        toolCallId: "spawn-a",
    });
    observe(machine, "tool.execution_start", startedAt + 3, {
        toolCallId: "spawn-b",
    });
    startSubagent(machine, startedAt + 4, "agent-a", "spawn-a");
    startSubagent(machine, startedAt + 5, "agent-b", "spawn-b");
    observe(machine, "tool.execution_complete", startedAt + 6, {
        toolCallId: "spawn-a",
    });
    observe(machine, "tool.execution_complete", startedAt + 7, {
        toolCallId: "spawn-b",
    });

    observe(
        machine,
        "tool.execution_start",
        startedAt + 8,
        { toolCallId: "child-a" },
        { agentRef: "agent-a", parentToolCallRef: "spawn-a" }
    );
    observe(
        machine,
        "tool.execution_start",
        startedAt + 9,
        { toolCallId: "child-b" },
        { agentRef: "agent-b", parentToolCallRef: "spawn-b" }
    );
    observe(
        machine,
        "tool.execution_complete",
        startedAt + 10,
        { toolCallId: "child-a" },
        { agentRef: "agent-a", parentToolCallRef: "spawn-a" }
    );
    observe(
        machine,
        "tool.execution_complete",
        startedAt + 11,
        { toolCallId: "child-b" },
        { agentRef: "agent-b", parentToolCallRef: "spawn-b" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 2);

    observe(
        machine,
        "subagent.completed",
        startedAt + 12,
        { toolCallId: "spawn-b" },
        { agentId: "agent-b" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 1);
    observe(
        machine,
        "subagent.completed",
        startedAt + 13,
        { toolCallId: "spawn-a" },
        { agentId: "agent-a" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 0);
    observe(machine, "assistant.turn_end", startedAt + 14, { turnId: 0 });
    observe(machine, "session.idle", startedAt + 15);

    const diagnostics = machine.drainSubagentDiagnostics();
    assert.deepEqual(
        diagnostics.map(({ reason, previousCount, nextCount }) => ({
            reason,
            previousCount,
            nextCount,
        })),
        [
            { reason: "matched-start", previousCount: null, nextCount: 1 },
            { reason: "matched-start", previousCount: 1, nextCount: 2 },
            { reason: "matching-terminal", previousCount: 2, nextCount: 1 },
            { reason: "matching-terminal", previousCount: 1, nextCount: 0 },
        ]
    );
});

test("root-turn boundary preserves known agent count between independent terminals", () => {
    const startedAt = 15_150;
    const scenarios = [
        {
            name: "absent-interval",
            times: {
                startA: 1,
                startB: 2,
                firstTerminal: 3,
                boundary: 4,
                secondTerminal: 5,
            },
        },
        {
            name: "closed-interval",
            times: {
                turnStart: 1,
                startA: 2,
                startB: 3,
                turnEnd: 4,
                firstTerminal: 5,
                boundary: 6,
                secondTerminal: 7,
            },
        },
    ];

    for (const scenario of scenarios) {
        const machine = createDiagnosticMachine(
            `fleet-root-boundary-${scenario.name}`,
            startedAt
        );
        const time = (key) => startedAt + scenario.times[key];
        if (scenario.times.turnStart !== undefined) {
            observe(machine, "assistant.turn_start", time("turnStart"), {
                turnId: 0,
            });
        }
        startSubagent(machine, time("startA"), "agent-a", "spawn-a");
        startSubagent(machine, time("startB"), "agent-b", "spawn-b");
        if (scenario.times.turnEnd !== undefined) {
            observe(machine, "assistant.turn_end", time("turnEnd"), {
                turnId: 0,
            });
        }

        observe(
            machine,
            "subagent.completed",
            time("firstTerminal"),
            { toolCallId: "spawn-a" },
            { agentId: "agent-a" }
        );
        assert.equal(machine.snapshot().activeSubagentCount, 1);

        observe(machine, "assistant.turn_end", time("boundary"), {
            turnId: 0,
        });
        assert.equal(machine.snapshot().activeSubagentCount, 1);
        assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);

        observe(
            machine,
            "subagent.completed",
            time("secondTerminal"),
            { toolCallId: "spawn-b" },
            { agentId: "agent-b" }
        );
        assert.equal(machine.snapshot().activeSubagentCount, 0);
        assert.deepEqual(
            machine.drainSubagentDiagnostics().map((record) => ({
                reason: record.reason,
                previousCount: record.previousCount,
                nextCount: record.nextCount,
            })),
            [
                { reason: "matched-start", previousCount: null, nextCount: 1 },
                { reason: "matched-start", previousCount: 1, nextCount: 2 },
                { reason: "matching-terminal", previousCount: 2, nextCount: 1 },
                { reason: "matching-terminal", previousCount: 1, nextCount: 0 },
            ]
        );
    }
});

test("root-turn boundary still suppresses an untrusted AIC delta", () => {
    const startedAt = 15_180;
    const machine = createSignalMachine("root-boundary-aic-suppression", startedAt);
    setBaseline(machine, 100, startedAt + 1);
    completeTurn(machine, 120, startedAt + 10);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 20);

    observe(machine, "assistant.turn_end", startedAt + 23, { turnId: 1 });
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);
});

test("root-turn closure and child-tool correlation failures preserve active agents", () => {
    const startedAt = 15_200;
    const machine = createDiagnosticMachine("fleet-root-closed-child", startedAt);
    observe(machine, "assistant.turn_start", startedAt + 1, { turnId: 0 });
    observe(machine, "tool.execution_start", startedAt + 2, {
        toolCallId: "spawn-a",
    });
    observe(machine, "tool.execution_start", startedAt + 3, {
        toolCallId: "spawn-b",
    });
    startSubagent(machine, startedAt + 4, "agent-a", "spawn-a");
    startSubagent(machine, startedAt + 5, "agent-b", "spawn-b");
    observe(machine, "tool.execution_complete", startedAt + 6, {
        toolCallId: "spawn-a",
    });
    observe(machine, "tool.execution_complete", startedAt + 7, {
        toolCallId: "spawn-b",
    });
    observe(machine, "assistant.turn_end", startedAt + 8, { turnId: 0 });
    assert.equal(machine.snapshot().activeSubagentCount, 2);

    observe(
        machine,
        "tool.execution_start",
        startedAt + 9,
        { toolCallId: "child-a" },
        { agentRef: "agent-a", parentToolCallRef: "spawn-a" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 2);
    observe(
        machine,
        "tool.execution_complete",
        startedAt + 10,
        { toolCallId: "child-a" },
        { agentRef: "agent-a", parentToolCallRef: "spawn-a" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 2);

    observe(
        machine,
        "subagent.completed",
        startedAt + 11,
        { toolCallId: "spawn-b" },
        { agentId: "agent-b" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 1);
    observe(
        machine,
        "subagent.completed",
        startedAt + 12,
        { toolCallId: "spawn-a" },
        { agentId: "agent-a" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 0);
    observe(machine, "session.idle", startedAt + 13);

    const diagnostics = machine.drainSubagentDiagnostics();
    const toolDiagnostics = diagnostics.filter((record) =>
        record.reason.startsWith("tool-")
    );
    assert.deepEqual(
        toolDiagnostics.map((record) => ({
            reason: record.reason,
            previousCount: record.previousCount,
            nextCount: record.nextCount,
            rootInterval: record.rootInterval,
            caller: record.caller,
            parentCorrelation: record.parentCorrelation,
        })),
        [
            {
                reason: "tool-start-root-turn-closed",
                previousCount: 2,
                nextCount: 2,
                rootInterval: "closed",
                caller: "subagent",
                parentCorrelation: "matched",
            },
            {
                reason: "tool-complete-unmatched-call-id",
                previousCount: 2,
                nextCount: 2,
                rootInterval: "closed",
                caller: "subagent",
                parentCorrelation: "matched",
            },
        ]
    );
    const serialized = JSON.stringify(toolDiagnostics);
    assert.equal(serialized.includes("agent-a"), false);
    assert.equal(serialized.includes("spawn-a"), false);
    assert.equal(serialized.includes("child-a"), false);
});

test("duplicate and missing tool IDs suppress AIC but not matched agent counts", () => {
    const startedAt = 15_300;
    const machine = createDiagnosticMachine("fleet-tool-id-errors", startedAt);
    observe(machine, "assistant.turn_start", startedAt + 1, { turnId: 0 });
    observe(machine, "tool.execution_start", startedAt + 2, {
        toolCallId: "spawn-a",
    });
    observe(machine, "tool.execution_start", startedAt + 3, {
        toolCallId: "spawn-b",
    });
    startSubagent(machine, startedAt + 4, "agent-a", "spawn-a");
    startSubagent(machine, startedAt + 5, "agent-b", "spawn-b");

    observe(machine, "tool.execution_start", startedAt + 6, {
        toolCallId: "spawn-a",
    });
    observe(machine, "tool.execution_start", startedAt + 7);
    observe(machine, "tool.execution_progress", startedAt + 8);
    observe(machine, "tool.execution_progress", startedAt + 9, {
        toolCallId: "unknown-progress-call",
    });
    observe(machine, "tool.execution_complete", startedAt + 10);
    observe(machine, "tool.execution_complete", startedAt + 11, {
        toolCallId: "unknown-complete-call",
    });
    machine.observe({
        ...event("tool.execution_progress", startedAt + 12, {
            toolCallId: "spawn-a",
        }),
        id: null,
        agentRef: "agent-a",
        parentToolCallRef: "spawn-a",
    });
    machine.observe({
        ...event("tool.execution_start", startedAt + 13, {
            toolCallId: "event-id-start-call",
        }),
        id: null,
    });
    machine.observe({
        ...event("tool.execution_complete", startedAt + 14, {
            toolCallId: "event-id-start-call",
        }),
        id: null,
    });
    assert.equal(machine.snapshot().activeSubagentCount, 2);

    const toolDiagnostics = machine
        .drainSubagentDiagnostics()
        .filter((record) => record.reason.startsWith("tool-"));
    assert.deepEqual(
        toolDiagnostics.map((record) => record.reason),
        [
            "tool-start-duplicate-call-id",
            "tool-start-missing-call-id",
            "tool-progress-missing-call-id",
            "tool-progress-unmatched-call-id",
            "tool-complete-missing-call-id",
            "tool-complete-unmatched-call-id",
            "tool-progress-missing-event-id",
            "tool-start-missing-event-id",
            "tool-complete-missing-event-id",
        ]
    );
    assert.ok(toolDiagnostics.every((record) =>
        record.previousCount === 2 &&
        record.nextCount === 2 &&
        ["root", "subagent"].includes(record.caller)
    ));
    for (const record of toolDiagnostics) {
        assert.deepEqual(Object.keys(record).sort(), [
            "atMs",
            "caller",
            "nextCount",
            "parentCorrelation",
            "previousCount",
            "reason",
            "rootInterval",
        ]);
    }
});

test("tool events without a root interval are diagnosed without invalidating agents", () => {
    const startedAt = 15_350;
    const scenarios = [
        {
            type: "tool.execution_start",
            data: { toolCallId: "untracked-start" },
            reason: "tool-start-interval-absent",
        },
        {
            type: "tool.execution_progress",
            data: { toolCallId: "untracked-progress" },
            reason: "tool-progress-interval-absent",
        },
        {
            type: "tool.execution_complete",
            data: { toolCallId: "untracked-complete" },
            reason: "tool-complete-interval-absent",
        },
    ];
    for (const [index, scenario] of scenarios.entries()) {
        const machine = createDiagnosticMachine(
            `fleet-no-root-interval-${index}`,
            startedAt
        );
        startSubagent(machine, startedAt + 1, "agent-a", "spawn-a");
        observe(
            machine,
            scenario.type,
            startedAt + 2,
            scenario.data,
            { agentRef: "agent-a", parentToolCallRef: "spawn-a" }
        );

        assert.equal(machine.snapshot().activeSubagentCount, 1);
        assert.deepEqual(machine.drainSubagentDiagnostics().at(-1), {
            atMs: startedAt + 2,
            reason: scenario.reason,
            previousCount: 1,
            nextCount: 1,
            rootInterval: "absent",
            caller: "subagent",
            parentCorrelation: "matched",
        });
    }
});

test("tool active-call capacity ambiguity does not invalidate agent counts", () => {
    const startedAt = 15_380;
    const machine = createDiagnosticMachine("fleet-tool-call-capacity", startedAt);
    observe(machine, "assistant.turn_start", startedAt + 1, { turnId: 0 });
    startSubagent(machine, startedAt + 2, "agent-a", "spawn-a");

    for (let index = 0; index < 32; index += 1) {
        observe(machine, "tool.execution_start", startedAt + 3 + index, {
            toolCallId: `active-call-${index}`,
        });
    }
    observe(machine, "tool.execution_start", startedAt + 35, {
        toolCallId: "over-capacity-call",
    });

    assert.equal(machine.snapshot().activeSubagentCount, 1);
    assert.deepEqual(machine.drainSubagentDiagnostics().at(-1), {
        atMs: startedAt + 35,
        reason: "tool-start-active-limit",
        previousCount: 1,
        nextCount: 1,
        rootInterval: "open",
        caller: "root",
        parentCorrelation: "missing",
    });
});

test("tool correlation ambiguity still suppresses AIC deltas without agents", () => {
    const machine = createDiagnosticMachine("tool-error-aic-only", 15_400);
    setBaseline(machine, 100, 15_410);
    observe(machine, "assistant.turn_start", 15_420, { turnId: 0 });
    observe(machine, "tool.execution_start", 15_421, {
        toolCallId: "tracked-tool",
    });
    observe(machine, "tool.execution_complete", 15_422, {
        toolCallId: "unmatched-tool",
    });
    observe(machine, "assistant.turn_end", 15_423, { turnId: 0 });
    observe(machine, "session.usage_checkpoint", 15_424, {
        totalNanoAiu: 120,
    });
    observe(machine, "assistant.idle", 15_425);
    observe(machine, "session.idle", 15_426);

    assert.equal(machine.snapshot().activeSubagentCount, null);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);
    const diagnostics = machine.drainSubagentDiagnostics();
    assert.deepEqual(diagnostics.at(-1), {
        atMs: 15_422,
        reason: "tool-complete-unmatched-call-id",
        previousCount: null,
        nextCount: null,
        rootInterval: "open",
        caller: "root",
        parentCorrelation: "missing",
    });
});

test("marks open subagents unknown on idle and resets that state on resume", () => {
    const machine = createSignalMachine("fleet-missing-terminal", 16_000);
    observe(
        machine,
        "subagent.started",
        16_010,
        { toolCallId: "spawn-call" },
        { agentId: "agent-1" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 1);

    observe(machine, "session.idle", 16_020);
    assert.equal(machine.snapshot().activeSubagentCount, null);

    observe(
        machine,
        "subagent.started",
        16_030,
        { toolCallId: "another-call" },
        { agentId: "agent-2" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, null);

    observe(machine, "session.resume", 16_040);
    assert.equal(machine.snapshot().activeSubagentCount, null);
    observe(
        machine,
        "subagent.started",
        16_050,
        { toolCallId: "new-call" },
        { agentId: "agent-3" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 1);
});

test("demotes an open subagent count to unknown after its lifecycle lease", () => {
    const startedAt = 16_100;
    const machine = createSignalMachine("fleet-expired-terminal", startedAt);
    observe(
        machine,
        "subagent.started",
        startedAt + 10,
        { toolCallId: "spawn-call" },
        { agentId: "agent-1" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 1);

    const expiredAt = startedAt + 300_011;
    assert.equal(machine.heartbeat(expiredAt), true);
    assert.equal(machine.snapshot().activeSubagentCount, null);
    assert.equal(machine.snapshot().updatedAtMs, expiredAt);

    observe(
        machine,
        "subagent.completed",
        expiredAt + 1,
        { toolCallId: "spawn-call" },
        { agentId: "agent-1" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, null);

    observe(machine, "session.resume", expiredAt + 2);
    observe(
        machine,
        "subagent.started",
        expiredAt + 3,
        { toolCallId: "new-spawn" },
        { agentId: "agent-2" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 1);

    const delayed = createSignalMachine("fleet-delayed-terminal", startedAt);
    observe(
        delayed,
        "subagent.started",
        startedAt + 10,
        { toolCallId: "delayed-spawn" },
        { agentId: "delayed-agent" }
    );
    observe(
        delayed,
        "subagent.completed",
        startedAt + 300_011,
        { toolCallId: "delayed-spawn" },
        { agentId: "delayed-agent" }
    );
    assert.equal(delayed.snapshot().activeSubagentCount, null);
});

test("retains a confirmed zero briefly, then expires it to unknown", () => {
    const startedAt = 16_200;
    const machine = createSignalMachine("fleet-confirmed-zero-lease", startedAt);
    observe(
        machine,
        "subagent.started",
        startedAt + 10,
        { toolCallId: "spawn-call" },
        { agentId: "agent-1" }
    );
    observe(
        machine,
        "subagent.completed",
        startedAt + 20,
        { toolCallId: "spawn-call" },
        { agentId: "agent-1" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 0);

    assert.equal(machine.heartbeat(startedAt + 300_020), true);
    assert.equal(machine.snapshot().activeSubagentCount, 0);
    assert.equal(machine.heartbeat(startedAt + 300_021), true);
    assert.equal(machine.snapshot().activeSubagentCount, null);
    assert.equal(machine.heartbeat(startedAt + 300_022), false);
});

test("keeps root turn completion distinct from an unknown subagent terminal", () => {
    const startedAt = 16_300;
    const machine = createSignalMachine("fleet-root-complete-unknown", startedAt);
    observe(machine, "assistant.turn_start", startedAt + 10, { turnId: 0 });
    observe(machine, "tool.execution_start", startedAt + 11, {
        toolCallId: "spawn-call",
    });
    observe(
        machine,
        "subagent.started",
        startedAt + 12,
        { toolCallId: "spawn-call" },
        { agentId: "agent-1" }
    );
    observe(machine, "tool.execution_complete", startedAt + 13, {
        toolCallId: "spawn-call",
    });
    observe(machine, "assistant.turn_end", startedAt + 14, { turnId: 0 });
    observe(machine, "session.idle", startedAt + 15);

    assert.equal(machine.snapshot().activeSubagentCount, null);
    assert.equal(machine.snapshot().phase, "complete");
});

test("clears a matching failed lifecycle without implying task success", () => {
    const machine = createSignalMachine("fleet-failed-terminal", 16_500);
    observe(
        machine,
        "subagent.started",
        16_510,
        { toolCallId: "failed-spawn-call" },
        { agentId: "failed-agent" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 1);

    observe(
        machine,
        "subagent.failed",
        16_520,
        { toolCallId: "failed-spawn-call" },
        { agentId: "failed-agent" }
    );
    assert.equal(machine.snapshot().activeSubagentCount, 0);
    assert.equal(JSON.stringify(machine.snapshot()).includes("failed-agent"), false);
});

test("suppresses the subagent count for missing or mismatched lifecycle IDs", () => {
    const missingId = createSignalMachine("fleet-missing-id", 17_000);
    observe(
        missingId,
        "subagent.started",
        17_010,
        { toolCallId: "spawn-call" }
    );
    assert.equal(missingId.snapshot().activeSubagentCount, null);

    const mismatch = createSignalMachine("fleet-mismatch", 18_000);
    observe(
        mismatch,
        "subagent.started",
        18_010,
        { toolCallId: "spawn-call-1" },
        { agentId: "agent-1" }
    );
    assert.equal(mismatch.snapshot().activeSubagentCount, 1);
    observe(
        mismatch,
        "subagent.completed",
        18_020,
        { toolCallId: "spawn-call-2" },
        { agentId: "agent-1" }
    );
    assert.equal(mismatch.snapshot().activeSubagentCount, null);
    observe(
        mismatch,
        "subagent.started",
        18_030,
        { toolCallId: "spawn-call-3" },
        { agentId: "agent-2" }
    );
    assert.equal(mismatch.snapshot().activeSubagentCount, null);
});

test("records matched starts and independent 2-to-1-to-0 terminals", () => {
    const startedAt = 19_000;
    const machine = createDiagnosticMachine("diagnostic-matched", startedAt);
    startSubagent(machine, startedAt + 1, "agent-private-a", "call-private-a");
    startSubagent(machine, startedAt + 2, "agent-private-b", "call-private-b");
    observe(
        machine,
        "subagent.completed",
        startedAt + 3,
        { toolCallId: "call-private-a" },
        { agentId: "agent-private-a" }
    );
    observe(
        machine,
        "subagent.failed",
        startedAt + 4,
        { toolCallId: "call-private-b" },
        { agentId: "agent-private-b" }
    );

    assert.equal(machine.snapshot().activeSubagentCount, 0);
    assert.equal(machine.snapshot().phase, null);
    const transitions = machine.drainSubagentDiagnostics();
    assert.deepEqual(transitions, [
        {
            atMs: startedAt + 1,
            reason: "matched-start",
            previousCount: null,
            nextCount: 1,
        },
        {
            atMs: startedAt + 2,
            reason: "matched-start",
            previousCount: 1,
            nextCount: 2,
        },
        {
            atMs: startedAt + 3,
            reason: "matching-terminal",
            previousCount: 2,
            nextCount: 1,
        },
        {
            atMs: startedAt + 4,
            reason: "matching-terminal",
            previousCount: 1,
            nextCount: 0,
        },
    ]);
    const serializedTransitions = JSON.stringify(transitions);
    assert.equal(serializedTransitions.includes("private-agent"), false);
    assert.equal(serializedTransitions.includes("private-call"), false);
    assert.equal(serializedTransitions.includes("fixture-event"), false);
    assert.deepEqual(Object.keys(machine.snapshot()).sort(), [
        "activeSubagentCount",
        "phase",
        "phaseAtMs",
        "recentAtMs",
        "recentIncreaseNanoAiu",
        "sessionId",
        "updatedAtMs",
        "version",
    ]);
});

test("records the specific conservative reason when an active count becomes unknown", () => {
    const startedAt = 20_000;
    const scenarios = [
        {
            name: "unmatched-terminal",
            reason: "unmatched-terminal",
            run(machine) {
                observe(
                    machine,
                    "subagent.completed",
                    startedAt + 2,
                    { toolCallId: "unmatched-call" },
                    { agentId: "unmatched-agent" }
                );
            },
        },
        {
            name: "mismatched-terminal-identity",
            reason: "ambiguous-identity",
            run(machine) {
                observe(
                    machine,
                    "subagent.completed",
                    startedAt + 2,
                    { toolCallId: "different-call" },
                    { agentId: "agent-1" }
                );
            },
        },
        {
            name: "missing-agent-identity",
            reason: "ambiguous-identity",
            run(machine) {
                observe(
                    machine,
                    "subagent.completed",
                    startedAt + 2,
                    { toolCallId: "spawn-call-1" }
                );
            },
        },
        {
            name: "duplicate-agent-start",
            reason: "ambiguous-identity",
            run(machine) {
                startSubagent(machine, startedAt + 2, "agent-1", "duplicate-call");
            },
        },
        {
            name: "session-idle-with-open-agent",
            reason: "session-idle-open-agent",
            run(machine) {
                observe(machine, "session.idle", startedAt + 2);
            },
        },
        {
            name: "session-idle-with-missing-event-id",
            reason: "session-idle-open-agent",
            run(machine) {
                machine.observe({
                    ...event("session.idle", startedAt + 2),
                    id: null,
                });
            },
        },
        {
            name: "session-idle-with-invalid-timestamp",
            reason: "session-idle-open-agent",
            run(machine) {
                machine.observe({
                    ...event("session.idle", startedAt + 2),
                    timestamp: "invalid",
                });
            },
        },
        {
            name: "subagent-with-invalid-timestamp",
            reason: "ambiguous-identity",
            run(machine) {
                machine.observe({
                    ...event("subagent.completed", startedAt + 2, {
                        toolCallId: "spawn-call-1",
                    }, {
                        agentId: "agent-1",
                    }),
                    timestamp: "invalid",
                });
            },
        },
        {
            name: "resume",
            reason: "resume-reset",
            run(machine) {
                observe(machine, "session.resume", startedAt + 2);
            },
        },
        {
            name: "session-start-reset",
            reason: "resume-reset",
            run(machine) {
                observe(machine, "session.start", startedAt + 2);
            },
        },
        {
            name: "context-clear-reset",
            reason: "resume-reset",
            run(machine) {
                observe(machine, "session.context_cleared", startedAt + 2);
            },
        },
        {
            name: "lifecycle-lease-expiry",
            reason: "lifecycle-lease-expiry",
            run(machine) {
                machine.heartbeat(startedAt + 300_002);
            },
        },
        {
            name: "out-of-order-event",
            reason: "ambiguous-event-order",
            run(machine) {
                observe(machine, "assistant.idle", startedAt);
            },
        },
        {
            name: "interruption",
            reason: "interruption",
            run(machine) {
                observe(machine, "assistant.interrupt", startedAt + 2);
            },
        },
        {
            name: "observer-reset",
            reason: "observer-reset",
            run(machine) {
                machine.reset(startedAt + 2);
            },
        },
    ];

    for (const [index, scenario] of scenarios.entries()) {
        const machine = createDiagnosticMachine(
            `diagnostic-unknown-${index}`,
            startedAt
        );
        startSubagent(machine, startedAt + 1);
        scenario.run(machine);

        assert.equal(
            machine.snapshot().activeSubagentCount,
            null,
            `${scenario.name} must suppress the positive claim`
        );
        const changes = machine.drainSubagentDiagnostics();
        const transition = changes.at(-1);
        assert.deepEqual(
            {
                reason: transition?.reason,
                previousCount: transition?.previousCount,
                nextCount: transition?.nextCount,
            },
            {
                reason: scenario.reason,
                previousCount: 1,
                nextCount: null,
            },
            scenario.name
        );
        assert.deepEqual(Object.keys(transition).sort(), [
            "atMs",
            "nextCount",
            "previousCount",
            "reason",
        ]);
        assert.equal("success" in transition, false);
        assert.equal("agentId" in transition, false);
        assert.equal("toolCallId" in transition, false);
    }
});

test("AIC-only ambiguity preserves matched agent identities", () => {
    const startedAt = 22_000;
    const scenarios = [
        {
            name: "missing-root-turn-event-id",
            apply(machine, timestampMs) {
                machine.observe({
                    ...event("assistant.turn_end", timestampMs),
                    id: null,
                });
            },
        },
        {
            name: "missing-checkpoint-event-id",
            apply(machine, timestampMs) {
                machine.observe({
                    ...event(
                        "session.usage_checkpoint",
                        timestampMs,
                        { totalNanoAiu: 125 }
                    ),
                    id: null,
                });
            },
        },
        {
            name: "invalid-checkpoint",
            apply(machine, timestampMs) {
                observe(machine, "session.usage_checkpoint", timestampMs, {
                    totalNanoAiu: "invalid",
                });
            },
        },
        {
            name: "permission-boundary",
            apply(machine, timestampMs) {
                observe(machine, "permission.requested", timestampMs);
            },
        },
        {
            name: "invalid-root-timestamp",
            apply(machine, timestampMs) {
                machine.observe({
                    ...event("assistant.idle", timestampMs),
                    timestamp: "invalid",
                });
            },
        },
    ];

    for (const [index, scenario] of scenarios.entries()) {
        const tracked = createDiagnosticMachine(
            `aic-only-count-${index}`,
            startedAt
        );
        startSubagent(tracked, startedAt + 1);
        scenario.apply(tracked, startedAt + 30);

        assert.equal(
            tracked.snapshot().activeSubagentCount,
            1,
            `${scenario.name} must not erase matched agent identity`
        );
        assert.deepEqual(tracked.drainSubagentDiagnostics(), [
            {
                atMs: startedAt + 1,
                reason: "matched-start",
                previousCount: null,
                nextCount: 1,
            },
        ]);

        const aic = createSignalMachine(`aic-only-delta-${index}`, startedAt);
        setBaseline(aic, 100, startedAt + 1);
        completeTurn(aic, 120, startedAt + 10);
        assert.equal(aic.snapshot().recentIncreaseNanoAiu, 20);
        scenario.apply(aic, startedAt + 30);
        assert.equal(
            aic.snapshot().recentIncreaseNanoAiu,
            null,
            `${scenario.name} must still suppress ambiguous AIC`
        );
    }
});

test("records capacity and confirmed-zero expiry without false running or success claims", () => {
    const startedAt = 21_000;
    const capacity = createDiagnosticMachine("diagnostic-capacity", startedAt);
    for (let index = 0; index < 16; index += 1) {
        startSubagent(
            capacity,
            startedAt + index + 1,
            `capacity-agent-${index}`,
            `capacity-call-${index}`
        );
    }
    startSubagent(capacity, startedAt + 17, "overflow-agent", "overflow-call");
    assert.equal(capacity.snapshot().activeSubagentCount, null);
    assert.deepEqual(capacity.drainSubagentDiagnostics().at(-1), {
        atMs: startedAt + 17,
        reason: "tracking-capacity",
        previousCount: 16,
        nextCount: null,
    });

    const confirmedZero = createDiagnosticMachine(
        "diagnostic-zero-expiry",
        startedAt
    );
    startSubagent(confirmedZero, startedAt + 1);
    observe(
        confirmedZero,
        "subagent.completed",
        startedAt + 2,
        { toolCallId: "spawn-call-1" },
        { agentId: "agent-1" }
    );
    assert.equal(confirmedZero.snapshot().activeSubagentCount, 0);
    assert.equal(confirmedZero.heartbeat(startedAt + 300_003), true);
    assert.equal(confirmedZero.snapshot().activeSubagentCount, null);
    assert.deepEqual(confirmedZero.drainSubagentDiagnostics().at(-1), {
        atMs: startedAt + 300_003,
        reason: "confirmed-zero-expiry",
        previousCount: 0,
        nextCount: null,
    });
});

test("diagnostic capture is opt-in and keeps state snapshots unchanged", () => {
    const disabled = createSignalMachine("diagnostic-disabled", 22_000);
    const enabled = createDiagnosticMachine("diagnostic-enabled", 22_000);
    startSubagent(disabled, 22_001);
    startSubagent(enabled, 22_001);

    assert.deepEqual(
        { ...disabled.snapshot(), sessionId: "same-session" },
        { ...enabled.snapshot(), sessionId: "same-session" }
    );
    assert.deepEqual(disabled.drainSubagentDiagnostics(), []);
    assert.equal(enabled.drainSubagentDiagnostics().length, 1);
});

test("keeps recent state fresh on heartbeats until the retention expires", () => {
    const machine = createSignalMachine("session-m", 12_000);
    setBaseline(machine, 100, 12_010);
    completeTurn(machine, 110, 12_020);

    const recentAtMs = machine.snapshot().recentAtMs;
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 10);

    for (const elapsedMs of [5_000, 10_000, 119_999, 120_000]) {
        const heartbeatAtMs = recentAtMs + elapsedMs;
        assert.equal(machine.heartbeat(heartbeatAtMs), true);
        assert.equal(machine.snapshot().recentIncreaseNanoAiu, 10);
        assert.equal(machine.snapshot().updatedAtMs, heartbeatAtMs);
    }

    assert.equal(machine.heartbeat(recentAtMs + 120_001), true);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);
    assert.equal(machine.snapshot().phase, "idle");
});

test("heartbeats preserve a genuinely long-running tool phase without showing progress", () => {
    const machine = createSignalMachine("session-o", 14_000);
    setBaseline(machine, 100, 14_010);
    observe(machine, "assistant.turn_start", 14_020, { turnId: 0 });
    observe(machine, "tool.execution_start", 14_021, {
        toolCallId: "long-running-tool",
    });

    assert.equal(machine.heartbeat(74_021), true);
    const snapshot = machine.snapshot();
    assert.equal(snapshot.phase, "running_tool");
    assert.equal(snapshot.phaseAtMs, 14_021);
    assert.equal(snapshot.updatedAtMs, 74_021);
    assert.deepEqual(Object.keys(snapshot).sort(), [
        "activeSubagentCount",
        "phase",
        "phaseAtMs",
        "recentAtMs",
        "recentIncreaseNanoAiu",
        "sessionId",
        "updatedAtMs",
        "version",
    ]);
});

test("deduplicates repeated event IDs without using turnId as identity", () => {
    const machine = createSignalMachine("session-n", 13_000);
    setBaseline(machine, 100, 13_010);

    const start = event("assistant.turn_start", 13_020, { turnId: 0 });
    machine.observe(start);
    machine.observe(start);
    observe(machine, "assistant.turn_end", 13_021, { turnId: 0 });
    observe(machine, "assistant.turn_start", 13_022, { turnId: 0 });
    observe(machine, "assistant.turn_end", 13_023, { turnId: 0 });
    observe(machine, "session.usage_checkpoint", 13_024, {
        totalNanoAiu: 120,
    });
    observe(machine, "session.idle", 13_025);

    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 20);
});

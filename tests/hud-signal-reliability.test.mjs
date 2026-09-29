import assert from "node:assert/strict";
import test from "node:test";
import { createSignalMachine } from "../.github/extensions/hud-signal-bridge/state-machine.mjs";

let nextId = 0;
const START = 1_000;

function event(type, atMs, data = {}, overrides = {}) {
    return {
        id: `reliability-event-${++nextId}`,
        type,
        timestamp: new Date(atMs).toISOString(),
        data,
        ...overrides,
    };
}

function observe(machine, type, atMs, data = {}, overrides = {}) {
    return machine.observe(event(type, atMs, data, overrides));
}

function readyMachine(name) {
    const machine = createSignalMachine(name, START, {
        recordAicValidation: true,
        bridgeSessionMatched: true,
    });
    observe(machine, "session.usage_checkpoint", START + 1, { totalNanoAiu: 100 });
    observe(machine, "assistant.idle", START + 2);
    observe(machine, "session.idle", START + 3);
    machine.drainAicValidation();
    return machine;
}

function closeInterval(machine, atMs = START + 30, totalNanoAiu = 135) {
    observe(machine, "assistant.turn_end", atMs, { turnId: 0 });
    observe(machine, "session.usage_checkpoint", atMs + 1, { totalNanoAiu });
    observe(machine, "session.idle", atMs + 2);
}

function assertValid(machine, difference = 35) {
    const snapshot = machine.snapshot();
    assert.equal(snapshot.recentIncreaseNanoAiu, difference);
    assert.equal(snapshot.recentSuppressedReason, null);
    const diagnostic = machine.drainAicValidation();
    assert.equal(diagnostic.validity, "valid");
    assert.equal(diagnostic.reason, "valid");
    assert.equal(diagnostic.baselineNanoAiu, 100);
    assert.equal(diagnostic.finalCheckpointNanoAiu, 100 + difference);
    assert.equal(diagnostic.computedDifferenceNanoAiu, difference);
    assert.equal(diagnostic.displayedIncreaseNanoAiu, difference);
    for (const flag of [
        "baselineBeforeInterval",
        "rootTurnsClosed",
        "finalCheckpointAccepted",
        "finalCheckpointAfterTurnEnd",
        "idleAfterFinalCheckpoint",
        "toolCallsClosed",
    ]) {
        assert.equal(diagnostic.eventOrder[flag], true, flag);
    }
    assert.equal(diagnostic.eventOrder.rootTurnsStarted, 1);
    assert.equal(diagnostic.eventOrder.rootTurnsEnded, 1);
    assert.equal(diagnostic.eventOrder.overlapObserved, false);
}

function assertSuppressed(machine, reason) {
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);
    assert.notEqual(machine.snapshot().recentSuppressedReason, null);
    const diagnostic = machine.drainAicValidation();
    assert.equal(diagnostic.validity, "suppressed");
    assert.equal(diagnostic.displayedIncreaseNanoAiu, null);
    if (reason) assert.equal(diagnostic.reason, reason);
    return diagnostic;
}

for (const order of [["call-a", "call-b"], ["call-b", "call-a"]]) {
    test(`correlated concurrent tools complete ${order.join(" then ")} within one root turn`, () => {
        const machine = readyMachine(`concurrent-${order[0]}`);
        observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
        observe(machine, "assistant.usage", START + 11, {
            copilotUsage: { totalNanoAiu: 9_999 },
        });
        for (const [index, toolCallId] of ["call-a", "call-b"].entries()) {
            observe(machine, "tool.execution_start", START + 12 + index, { toolCallId });
        }
        for (const [index, toolCallId] of ["call-a", "call-b"].entries()) {
            observe(machine, "tool.execution_progress", START + 14 + index, { toolCallId });
            assert.equal(machine.snapshot().phase, "running_tool");
            assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);
        }
        observe(machine, "tool.execution_complete", START + 16, { toolCallId: order[0] });
        assert.equal(machine.snapshot().phase, "running_tool");
        observe(machine, "tool.execution_progress", START + 17, { toolCallId: order[1] });
        assert.equal(machine.snapshot().phase, "running_tool");
        observe(machine, "tool.execution_complete", START + 18, { toolCallId: order[1] });
        assert.equal(machine.snapshot().phase, "working");
        closeInterval(machine);
        assertValid(machine);
    });
}

test("parallel tools in sequential internal turns share one checkpoint interval", () => {
    const machine = readyMachine("parallel-internal-turns");
    for (const turn of [0, 1]) {
        const at = START + 10 + turn * 10;
        observe(machine, "assistant.turn_start", at, { turnId: turn });
        observe(machine, "tool.execution_start", at + 1, { toolCallId: `first-${turn}` });
        observe(machine, "tool.execution_start", at + 2, { toolCallId: `second-${turn}` });
        observe(machine, "tool.execution_complete", at + 3, { toolCallId: `second-${turn}` });
        observe(machine, "tool.execution_complete", at + 4, { toolCallId: `first-${turn}` });
        observe(machine, "assistant.turn_end", at + 5, { turnId: turn });
    }
    observe(machine, "session.usage_checkpoint", START + 30, { totalNanoAiu: 135 });
    observe(machine, "session.idle", START + 31);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 35);
    const diagnostic = machine.drainAicValidation();
    assert.equal(diagnostic.validity, "valid");
    assert.equal(diagnostic.eventOrder.rootTurnsStarted, 2);
    assert.equal(diagnostic.eventOrder.rootTurnsEnded, 2);
    assert.equal(diagnostic.eventOrder.toolCallsClosed, true);
    assert.equal(diagnostic.eventOrder.overlapObserved, false);
});

test("identical tool event deliveries are deduplicated, not duplicate call starts", () => {
    const machine = readyMachine("tool-event-dedupe");
    observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
    for (const [index, type] of [
        "tool.execution_start",
        "tool.execution_progress",
        "tool.execution_complete",
    ].entries()) {
        const delivery = event(type, START + 11 + index, { toolCallId: "call-a" });
        assert.equal(machine.observe(delivery), true);
        assert.equal(machine.observe(delivery), false);
    }
    closeInterval(machine);
    assertValid(machine);
});

const correlationCases = [
    ["duplicate-start", "tool.execution_start", { toolCallId: "call-a" }],
    ["unmatched-progress", "tool.execution_progress", { toolCallId: "unknown-call" }],
    ["unmatched-complete", "tool.execution_complete", { toolCallId: "unknown-call" }],
    ...["start", "progress", "complete"].flatMap((action) => [
        [`missing-${action}-call-id`, `tool.execution_${action}`, {}],
        [`unsafe-${action}-call-id`, `tool.execution_${action}`, { toolCallId: "unsafe call" }],
        [`missing-${action}-event-id`, `tool.execution_${action}`, { toolCallId: "call-a" }, { id: undefined }],
        [`unsafe-${action}-event-id`, `tool.execution_${action}`, { toolCallId: "call-a" }, { id: "unsafe event" }],
    ]),
];

for (const [name, type, data, overrides] of correlationCases) {
    test(`ambiguous tool correlation stays suppressed: ${name}`, () => {
        const machine = readyMachine(name);
        observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
        observe(machine, "tool.execution_start", START + 11, { toolCallId: "call-a" });
        observe(machine, type, START + 12, data, overrides);
        observe(machine, "tool.execution_complete", START + 13, { toolCallId: "call-a" });
        closeInterval(machine);
        assertSuppressed(machine, "tool-correlation");
    });
}

test("a second completion with a new event ID is not deduplicated", () => {
    const machine = readyMachine("duplicate-tool-complete");
    observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
    observe(machine, "tool.execution_start", START + 11, { toolCallId: "call-a" });
    observe(machine, "tool.execution_complete", START + 12, { toolCallId: "call-a" });
    observe(machine, "tool.execution_complete", START + 13, { toolCallId: "call-a" });
    closeInterval(machine);
    assertSuppressed(machine, "tool-correlation");
});

test("genuinely overlapping root turns remain suppressed", () => {
    const machine = readyMachine("root-overlap");
    observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
    observe(machine, "assistant.turn_start", START + 11, { turnId: 1 });
    observe(machine, "assistant.turn_end", START + 12, { turnId: 1 });
    closeInterval(machine);
    const diagnostic = assertSuppressed(machine, "overlapping-turns");
    assert.equal(diagnostic.eventOrder.overlapObserved, true);
});

for (const completeAfterEnd of [false, true]) {
    test(`tools open at root turn end remain suppressed (${completeAfterEnd ? "late completion" : "unfinished"})`, () => {
        const machine = readyMachine(`open-tool-${completeAfterEnd}`);
        observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
        observe(machine, "tool.execution_start", START + 11, { toolCallId: "call-a" });
        observe(machine, "assistant.turn_end", START + 12, { turnId: 0 });
        if (completeAfterEnd) {
            observe(machine, "tool.execution_complete", START + 13, { toolCallId: "call-a" });
        }
        observe(machine, "session.usage_checkpoint", START + 14, { totalNanoAiu: 135 });
        observe(machine, "session.idle", START + 15);
        const diagnostic = assertSuppressed(machine);
        if (!completeAfterEnd) assert.equal(diagnostic.eventOrder.toolCallsClosed, false);
    });
}

test("checkpoint before final root turn end cannot publish an exact delta", () => {
    const machine = readyMachine("early-checkpoint");
    observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
    observe(machine, "session.usage_checkpoint", START + 11, { totalNanoAiu: 135 });
    observe(machine, "assistant.turn_end", START + 12, { turnId: 0 });
    observe(machine, "session.idle", START + 13);
    assertSuppressed(machine, "checkpoint-before-turn-end");
});

test("matched subagent lifecycle still does not establish root-only usage attribution", () => {
    const machine = readyMachine("subagent-attribution");
    observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
    observe(machine, "subagent.started", START + 11,
        { toolCallId: "spawn-call" }, { agentId: "agent-a" });
    observe(machine, "subagent.completed", START + 12,
        { toolCallId: "spawn-call" }, { agentId: "agent-a" });
    closeInterval(machine);
    const diagnostic = assertSuppressed(machine, "unverified-subagent-attribution");
    assert.equal(diagnostic.eventOrder.unverifiedSubagentActivity, true);
});

for (const [name, data, overrides] of [
    ["agent-id", {}, { agentId: "agent-a" }],
    ["parent-tool-call-id", { parentToolCallId: "spawn-call" }, {}],
    ["legacy-agent-ref", {}, { agentRef: "agent-a" }],
    ["legacy-parent-tool-call-ref", {}, { parentToolCallRef: "spawn-call" }],
]) {
    test(`subagent-tagged tool without lifecycle stays suppressed until reset: ${name}`, () => {
        const machine = readyMachine(`tagged-tool-${name}`);
        observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
        observe(machine, "tool.execution_start", START + 11,
            { toolCallId: "call-a", ...data }, overrides);
        observe(machine, "tool.execution_progress", START + 12, { toolCallId: "call-a" });
        observe(machine, "tool.execution_complete", START + 13, { toolCallId: "call-a" });
        closeInterval(machine);
        const diagnostic = assertSuppressed(machine, "unverified-subagent-attribution");
        assert.equal(machine.snapshot().recentSuppressedReason, "subagent");
        assert.equal(diagnostic.eventOrder.unverifiedSubagentActivity, true);
        assert.equal(machine.snapshot().activeSubagentCount, null);

        observe(machine, "assistant.turn_start", START + 40, { turnId: 1 });
        closeInterval(machine, START + 50, 140);
        assertSuppressed(machine, "unverified-subagent-attribution");
        assert.equal(machine.snapshot().recentSuppressedReason, "subagent");

        machine.reset(START + 60);
        machine.drainAicValidation();
        observe(machine, "session.usage_checkpoint", START + 61, { totalNanoAiu: 100 });
        observe(machine, "session.idle", START + 62);
        machine.drainAicValidation();
        observe(machine, "assistant.turn_start", START + 70, { turnId: 0 });
        closeInterval(machine, START + 80);
        assertValid(machine);
    });
}

test("counter reset suppresses its interval", () => {
    const machine = readyMachine("counter-reset");
    observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
    closeInterval(machine, START + 30, 40);
    const diagnostic = assertSuppressed(machine, "counter-reset");
    assert.equal(diagnostic.eventOrder.counterResetObserved, true);
});

test("out-of-order event time suppresses usage without moving freshness backward", () => {
    const machine = readyMachine("event-clock-regression");
    observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
    const updatedAtMs = machine.snapshot().updatedAtMs;
    observe(machine, "assistant.turn_end", START + 9, { turnId: 0 });
    const afterRegression = machine.snapshot().updatedAtMs;
    observe(machine, "session.usage_checkpoint", START + 11, { totalNanoAiu: 135 });
    observe(machine, "session.idle", START + 12);
    assertSuppressed(machine, "ambiguous-event-order");
    assert.ok(afterRegression >= updatedAtMs);
});

test("a new busy interval immediately clears the previous suppression reason", () => {
    const machine = readyMachine("suppression-clears");
    observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
    observe(machine, "tool.execution_progress", START + 11, { toolCallId: "unknown-call" });
    closeInterval(machine);
    assertSuppressed(machine, "tool-correlation");
    observe(machine, "assistant.turn_start", START + 40, { turnId: 1 });
    assert.equal(machine.snapshot().recentSuppressedReason, null);
    assert.equal(machine.snapshot().recentAtMs, null);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);
});

test("attached idle machine without a delta remains fresh on repeated heartbeats", () => {
    const machine = readyMachine("idle-no-delta");
    const phaseAtMs = machine.snapshot().phaseAtMs;
    for (const atMs of [START + 20, START + 120_020, START + 240_020]) {
        assert.equal(machine.heartbeat(atMs), true);
        assert.equal(machine.snapshot().updatedAtMs, atMs);
        assert.equal(machine.snapshot().phase, "idle");
        assert.equal(machine.snapshot().phaseAtMs, phaseAtMs);
        assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);
        assert.equal(machine.snapshot().activeSubagentCount, null);
    }
});

for (const suppressed of [false, true]) {
    test(`${suppressed ? "suppressed" : "valid"} recent value expires only after 120000ms and idle keeps refreshing`, () => {
        const machine = readyMachine(`retention-${suppressed}`);
        observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
        if (suppressed) {
            observe(machine, "tool.execution_progress", START + 11, { toolCallId: "unknown-call" });
        }
        closeInterval(machine);
        if (suppressed) assertSuppressed(machine, "tool-correlation");
        else assertValid(machine);
        const before = machine.snapshot();
        for (const elapsed of [119_999, 120_000]) {
            assert.equal(machine.heartbeat(before.recentAtMs + elapsed), true);
            assert.equal(machine.snapshot().recentIncreaseNanoAiu, before.recentIncreaseNanoAiu);
            assert.equal(machine.snapshot().recentSuppressedReason, before.recentSuppressedReason);
            assert.equal(machine.snapshot().recentAtMs, before.recentAtMs);
            assert.equal(machine.snapshot().updatedAtMs, before.recentAtMs + elapsed);
        }
        for (const elapsed of [120_001, 125_000, 240_000]) {
            const atMs = before.recentAtMs + elapsed;
            assert.equal(machine.heartbeat(atMs), true);
            assert.equal(machine.snapshot().updatedAtMs, atMs);
            assert.equal(machine.snapshot().phase, "idle");
            assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);
            assert.equal(machine.snapshot().recentSuppressedReason, null);
            assert.equal(machine.snapshot().recentAtMs, null);
            assert.equal(machine.snapshot().activeSubagentCount, null);
        }
    });
}

test("complete phase is retained at 10000ms and becomes fresh idle strictly afterward", () => {
    const machine = readyMachine("complete-retention");
    observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
    closeInterval(machine);
    const { phaseAtMs, recentAtMs } = machine.snapshot();
    assert.equal(machine.snapshot().phase, "complete");
    assert.equal(machine.heartbeat(phaseAtMs + 10_000), true);
    assert.equal(machine.snapshot().phase, "complete");
    assert.equal(machine.snapshot().phaseAtMs, phaseAtMs);
    assert.equal(machine.heartbeat(phaseAtMs + 10_001), true);
    assert.equal(machine.snapshot().phase, "idle");
    assert.equal(machine.snapshot().phaseAtMs, phaseAtMs + 10_001);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 35);
    assert.equal(machine.snapshot().recentAtMs, recentAtMs);
    assert.equal(machine.heartbeat(recentAtMs + 120_001), true);
    assert.equal(machine.heartbeat(recentAtMs + 120_002), true);
    assert.equal(machine.snapshot().updatedAtMs, recentAtMs + 120_002);
});

test("heartbeat refreshes attachment without fabricating a phase or known subagent count", () => {
    const machine = createSignalMachine("unknown-state", START);
    const before = machine.snapshot();
    assert.equal(machine.heartbeat(START + 120_001), true);
    assert.deepEqual(machine.snapshot(), { ...before, updatedAtMs: START + 120_001 });
});

test("invalid heartbeat timestamps leave all state unchanged", () => {
    const machine = readyMachine("invalid-heartbeat");
    observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
    closeInterval(machine);
    const before = machine.snapshot();
    for (const atMs of [NaN, Infinity, -1, 1.5, "2000", null, Number.MAX_SAFE_INTEGER + 1]) {
        assert.equal(machine.heartbeat(atMs), false);
        assert.deepEqual(machine.snapshot(), before);
    }
});

test("a regressing heartbeat cannot move freshness backward", () => {
    const machine = readyMachine("heartbeat-regression");
    observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
    closeInterval(machine);
    machine.heartbeat(START + 5_000);
    const before = machine.snapshot();
    machine.heartbeat(START + 4_999);
    assert.deepEqual(machine.snapshot(), before);
});

test("bad event timestamp suppresses usage without making freshness older", () => {
    const machine = readyMachine("invalid-event-time");
    observe(machine, "assistant.turn_start", START + 10, { turnId: 0 });
    const before = machine.snapshot().updatedAtMs;
    observe(machine, "tool.execution_progress", START + 11,
        { toolCallId: "call-a" }, { timestamp: "invalid" });
    assert.ok(machine.snapshot().updatedAtMs >= before);
    closeInterval(machine);
    assertSuppressed(machine, "ambiguous-event");
});

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
    observe(machine, "subagent.started", 11_021, { agentId: "child-1" });
    observe(machine, "assistant.turn_end", 11_022, { turnId: 0 });
    observe(machine, "session.usage_checkpoint", 11_023, {
        totalNanoAiu: 140,
    });
    observe(machine, "session.idle", 11_024);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);

    completeTurn(machine, 150, 11_030);
    assert.equal(machine.snapshot().recentIncreaseNanoAiu, null);
});

test("expires the recent delta and completion phase", () => {
    const machine = createSignalMachine("session-m", 12_000);
    setBaseline(machine, 100, 12_010);
    completeTurn(machine, 110, 12_020);

    assert.equal(machine.snapshot().recentIncreaseNanoAiu, 10);
    assert.equal(machine.heartbeat(12_020 + 12 + 120_001), true);
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
    assert.equal(snapshot.phase, "running-tool");
    assert.equal(snapshot.phaseAtMs, 14_021);
    assert.equal(snapshot.updatedAtMs, 74_021);
    assert.deepEqual(Object.keys(snapshot).sort(), [
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
